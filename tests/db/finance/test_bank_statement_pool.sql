-- ============================================================
-- test_bank_statement_pool -- Pool-Regel auf der Bank-Seite (Bank-Import-Modul Paket 3)
--   fn_statement_prepare: Gegenpart-Name passt zum counterparty_pattern eines Profils (Bondora) und kein eigenes
--   Konto per IBAN -> Kandidaten = P2P-Konten dieses Profils. Eingang: Verrechnungskonto = dieses Konto, sonst gleicher
--   Inhaber (nie Haushalt) -> Transfer + Gebuehr-Bein beim P2P-Konto. Ausgang: Referenz (Kontonummer als ganzes Wort im
--   Verwendungszweck), sonst bei GENAU einer Zahlung mit zwei Kandidaten transfer_choice_required (der Agent fragt) bzw.
--   transfer_account; 'none' oder mehrere solche Zahlungen -> Rest + Hinweis. Danach erkennt der Bondora-Export die
--   Auszahlung (Gruppe inkl. Gebuehr).
--   Werte und Referenzen erfunden.
-- ============================================================
BEGIN;
DO $$
DECLARE
    ps   DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe   DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_tr INT; v_tr2 INT; v_ga INT; v_gb INT;
    v_s  JSONB; v_res JSONB; v_app JSONB; v_m JSONB;
BEGIN
    INSERT INTO agent.persons (person_id, full_name, role) VALUES ('pl_a', 'Person A', 'partner'), ('pl_b', 'Person B', 'child');
    v_tr  := (finance.fn_create_account(jsonb_build_object('name', '__t_pl_tr__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'owner_person_id', 'pl_a', 'opening_balance', 1000, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_tr2 := (finance.fn_create_account(jsonb_build_object('name', '__t_pl_tr2__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'owner_person_id', 'pl_b', 'opening_balance', 100, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_ga  := (finance.fn_create_account(jsonb_build_object('name', '__t_pl_gga__', 'account_type', 'p2p', 'currency', 'EUR',
                 'bank', 'Bondora', 'owner_person_id', 'pl_a', 'account_number', 'BNDREF111', 'settlement_id', v_tr,
                 'opening_balance', 600, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_gb  := (finance.fn_create_account(jsonb_build_object('name', '__t_pl_ggb__', 'account_type', 'p2p', 'currency', 'EUR',
                 'bank', 'Bondora', 'owner_person_id', 'pl_b', 'account_number', 'BNDREF222',
                 'opening_balance', 300, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    -- ein Depot mit Bondora-Bank am selben Verrechnungskonto ist nie Kandidat (nur P2P)
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_pl_depot__', 'account_type', 'stocks_depot', 'currency', 'EUR',
                 'bank', 'Bondora', 'settlement_id', v_tr));
    IF v_ga IS NULL OR v_gb IS NULL THEN RAISE EXCEPTION 'SETUP accounts'; END IF;

    v_s := jsonb_build_object('account_name', '__t_pl_tr__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 1000, 'closing_balance', 1000 + 200 - 100 - 50,
        'lines', jsonb_build_array(
            jsonb_build_object('date', ps + 3, 'amount', 200, 'counterparty', 'Go&Grow OU', 'purpose', 'Auszahlung'),
            jsonb_build_object('date', ps + 5, 'amount', -100, 'counterparty', 'Bondora Capital Oü', 'purpose', 'Einzahlung BNDREF222'),
            -- Referenz nur als Teil eines laengeren Worts -> keine Referenz -> zwei Kandidaten
            jsonb_build_object('date', ps + 7, 'amount', -50, 'counterparty', 'Bondora Capital Oü', 'purpose', 'Sparen BNDREF2229')));

    -- ---------- Rueckfrage noetig: genau eine Zahlung passt zu zwei Konten (Kandidaten als Daten, keine Karte) ----------
    v_res := finance.fn_statement_prepare(v_s);
    IF v_res->>'code' IS DISTINCT FROM 'transfer_choice_required' OR v_res ? 'card_lines'
       OR v_res->'candidates' <> jsonb_build_array('__t_pl_gga__', '__t_pl_ggb__')
       OR (v_res->>'amount')::numeric <> -50 OR (v_res->>'date')::date <> ps + 7 THEN
        RAISE EXCEPTION 'FAIL [P1 transfer_choice_required]: %', v_res;
    END IF;
    -- Name passt zu keinem der beiden -> erneut fragen (nie still in den Rest)
    v_res := finance.fn_statement_prepare(v_s || '{"transfer_account": "Bondora von Person C"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'transfer_choice_required' OR position('Bondora von Person C' IN v_res->>'reason') = 0 THEN
        RAISE EXCEPTION 'FAIL [P1b unbekannte Wahl -> erneut fragen]: %', v_res;
    END IF;
    -- "keins von beiden": Rest + Hinweis
    v_res := finance.fn_statement_prepare(v_s || '{"transfer_account": "none"}'::jsonb);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric <> -50 OR (v_res->>'pool_unassigned')::int <> 1
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'card_lines') c WHERE c->>'value' = 'finance.note.statement_pool_unassigned') THEN
        RAISE EXCEPTION 'FAIL [P2a keins von beiden -> Rest + Hinweis]: %', v_res;
    END IF;
    -- ZWEI solche Zahlungen: nie EINE Wahl fuer alle -> keine Rueckfrage, beide im Rest + Hinweis
    v_res := finance.fn_statement_prepare(v_s || jsonb_build_object('closing_balance', 1000 + 200 - 100 - 50 - 30,
                 'lines', (v_s->'lines') || jsonb_build_array(
                     jsonb_build_object('date', ps + 8, 'amount', -30, 'counterparty', 'Bondora Capital Oü', 'purpose', 'Sparen'))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric <> -80 OR (v_res->>'pool_unassigned')::int <> 2 THEN
        RAISE EXCEPTION 'FAIL [P2b zwei unklare Zahlungen -> Rest]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [P1-P2 Rueckfrage / ohne Wahl]';

    -- ---------- mit Wahl: Eingang (Verrechnungskonto) + Gebuehr, Ausgang per Referenz, Ausgang per Wahl ----------
    v_s := v_s || jsonb_build_object('transfer_account', '__t_pl_ggb__');
    v_res := finance.fn_statement_prepare(v_s);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [P3 prepare mit Wahl]: %', v_res;
    END IF;
    IF (SELECT string_agg(((m->>'amount')::numeric)::int || ':' || (m->>'other_account_id') || ':' || COALESCE(m->>'partner_fee', '-'), ','
                          ORDER BY (m->>'line_date')::date)
        FROM jsonb_array_elements(v_res->'matched') m)
       IS DISTINCT FROM '200:' || v_ga || ':1.00,-100:' || v_gb || ':-,-50:' || v_gb || ':-' THEN
        RAISE EXCEPTION 'FAIL [P4 Pool-Zuordnung]: %', v_res->'matched';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'card_lines') c
                   WHERE c->'value'->>'value' = 'finance.tpl.statement_partner_fee_row'
                     AND (c->'value'->'params'->'fee'->>'value')::numeric = 1) THEN
        RAISE EXCEPTION 'FAIL [P5 Karte zeigt die Gebuehr beim Gegenkonto]: %', v_res->'card_lines';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_res->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_tr) <> 1050
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_ga) <> 399
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_gb) <> 450
       OR (SELECT count(*) FROM finance.transactions f JOIN finance.transactions t ON t.group_id = f.group_id
           WHERE f.account_id = v_ga AND f.category = 'fee' AND f.amount = -1 AND t.account_id = v_tr AND t.amount = 200) <> 1 THEN
        RAISE EXCEPTION 'FAIL [P6 Buchung]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [P3-P6 Pool-Regel mit Wahl]';

    -- ---------- Bondora-Export danach: die Auszahlung (-201) trifft die Gruppe inkl. Gebuehr ----------
    v_res := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'account_name', '__t_pl_gga__',
        'table', jsonb_build_object('rows', jsonb_build_array(
            jsonb_build_array('', '', '', 'Summary', ''),
            jsonb_build_array(to_char(ps, 'FMMM/FMDD/YYYY') || '-' || to_char(pe, 'FMMM/FMDD/YYYY'), '', '', 'Opening', '600'),
            jsonb_build_array('', '', '', 'Payments in', '0'), jsonb_build_array('', '', '', 'Payments out', '201'),
            jsonb_build_array('', '', '', 'Closing', '399'),
            jsonb_build_array('Date', 'Payment type', 'In', 'Out', 'Balance'),
            jsonb_build_array(to_char(ps + 2, 'FMMM/FMDD/YYYY'), 'Withdrawal to bank account', '', '201', '399')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'already_booked') <> 1
       OR jsonb_array_length(v_res->'matched') <> 0 OR (v_res->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [P7 Bondora danach]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [P7 Bondora danach]';

    -- ---------- Eingang ohne Verrechnungskonto: gleicher Inhaber ----------
    v_res := finance.fn_statement_prepare(jsonb_build_object('account_name', '__t_pl_tr2__', 'currency', 'EUR',
        'period_start', ps, 'period_end', pe, 'opening_balance', 100, 'closing_balance', 130,
        'lines', jsonb_build_array(jsonb_build_object('date', ps + 4, 'amount', 30, 'counterparty', 'Go&Grow OU'))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->'matched'->0->>'other_account_id')::int IS DISTINCT FROM v_gb
       OR (v_res->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [P8 Inhaber-Fallback]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [P8 Inhaber-Fallback]';

    -- ---------- schon abgeglichenes P2P-Konto ist nie Kandidat (sein Auszug hat die Bewegung schon verarbeitet) ----------
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_gb, 'confirmed_balance',
                (SELECT balance FROM finance.account_balances WHERE account_id = v_gb), 'reconciliation_date', pe::text));
    v_res := finance.fn_statement_prepare(jsonb_build_object('account_name', '__t_pl_tr2__', 'currency', 'EUR',
        'period_start', ps, 'period_end', pe, 'opening_balance', 100, 'closing_balance', 130,
        'lines', jsonb_build_array(jsonb_build_object('date', ps + 4, 'amount', 30, 'counterparty', 'Go&Grow OU'))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'matched') <> 0
       OR (v_res->>'lump')::numeric <> 30 OR (v_res->>'pool_unassigned')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [P9 abgeglichenes P2P-Konto nie Kandidat]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [P9 abgeglichen -> kein Kandidat]';
END $$;
ROLLBACK;
