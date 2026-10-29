-- ============================================================
-- test_bank_statement_bondora -- Monats-Check aus dem Bondora-Export (Bank-Import-Modul Paket 2)
--   fn_statement_prepare (source:'file', gedruckter Auszug aus der Datei) + fn_apply_bank_statement +
--   fn_void_bank_statement, fn_set_account (Verrechnungskonto fuer p2p). Werte erfunden, Daten relativ zu heute.
--   Szenario: TR-Girokonto (1000) = Verrechnungskonto des Go&Grow-Kontos (100), taeglicher Zins mit zwei vom
--   Scheduler gebuchten Tagen (0.03 / 8.00, Bondora sagt 0.02 / 8.71), Dauerauftrag TR->Go&Grow 50.
--   Export: Zins, Kleinbetrag (Altkredit), Info-Zeile, Einzahlung 500, Zins, Dauerauftrag 50, Auszahlung 201 (1 Gebuehr).
--   Erwartet: kein Owner-Saldo noetig, Rest 0, EINE Zinskorrektur 0.70, EINE Altkredit-Buchung 0.15, offene
--   Zins-Vorkommen uebersprungen, Transfers mit dem Verrechnungskonto (Auszahlung 200 + Gebuehr 1 in einer Gruppe),
--   danach erkennt der TR-Auszug alles als gebucht; ohne Verrechnungskonto -> Rest + Hinweis.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.bd(p_d date, p_typ text, p_in text, p_out text, p_bal text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(to_char(p_d, 'FMMM/FMDD/YYYY'), p_typ, p_in, p_out, p_bal);
$$;
DO $$
DECLARE
    ps    DATE := date_trunc('month', CURRENT_DATE - 45)::date;
    pe    DATE := (date_trunc('month', CURRENT_DATE - 45) + interval '1 month - 1 day')::date;
    v_tr  INT; v_gg INT; v_gg2 INT; r_spar INT;
    v_res JSONB; v_prep JSONB; v_app JSONB; v_p JSONB; v_grid JSONB;
    v_o   RECORD;
    v_open_before INT;
BEGIN
    -- ---------- Setup ----------
    v_tr := (finance.fn_create_account(jsonb_build_object('name', '__t_bb_tr__', 'account_type', 'cash', 'currency', 'EUR',
                'bank', 'Trade Republic', 'account_number', 'DE89370400440532013000',
                'opening_balance', 1000, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_gg := (finance.fn_create_account(jsonb_build_object('name', '__t_bb_gg__', 'account_type', 'p2p', 'currency', 'EUR',
                'bank', 'Bondora', 'opening_balance', 100, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_res := finance.fn_set_account(jsonb_build_object('account_id', v_gg, 'settlement_id', v_tr));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT settlement_account_id FROM finance.accounts WHERE id = v_gg) IS DISTINCT FROM v_tr THEN
        RAISE EXCEPTION 'FAIL [S0 Verrechnungskonto fuer p2p]: %', v_res;
    END IF;
    INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, valid_from)
    VALUES (v_gg, 6, 1, 'day', ps);
    -- taegliches Raster: value_date = period_end (die Korrektur rechnet je Zeitraum, nie je Tag)
    IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open(pe) o WHERE o.account_id = v_gg AND o.value_date <> o.period_end) THEN
        RAISE EXCEPTION 'FAIL [S0b taegliches Raster value_date = period_end]';
    END IF;
    -- zwei Tage schaetzt der Scheduler schon (der 1. und der 4. offene Tag; Bondora sagt 0.02 / 8.71)
    FOR v_o IN SELECT x.*, x.rn FROM (SELECT o.*, row_number() OVER (ORDER BY o.value_date) AS rn
                                    FROM finance.fn_interest_due_open(pe) o WHERE o.account_id = v_gg) x WHERE x.rn IN (1, 4) LOOP
        v_res := finance.fn_book_interest_occurrence(jsonb_build_object('account_id', v_gg, 'value_date', v_o.value_date,
                     'period_end', v_o.period_end, 'amount', CASE WHEN v_o.rn = 1 THEN 0.03 ELSE 8.00 END));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP zins: %', v_res; END IF;
    END LOOP;
    SELECT count(*) INTO v_open_before FROM finance.fn_interest_due_open(pe) o WHERE o.account_id = v_gg AND o.period_end <= pe;
    r_spar := finance.fn_add_recurring_payment(v_tr, -50, 'Go&Grow Sparrate', 1::smallint, 'month'::finance.schedule_unit,
                  extract(day FROM ps + 5)::smallint, (ps - interval '1 month')::date, (ps - interval '1 month')::date, NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_gg WHERE id = r_spar;
    -- Vormonat schon erledigt (sonst waere er "fehlend")
    PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_spar,
                'due_date', ((ps + 5) - interval '1 month')::date));

    v_grid := jsonb_build_array(
        jsonb_build_array('Test Person', '', '', 'Summary', ''),
        jsonb_build_array(to_char(ps, 'FMMM/FMDD/YYYY') || '-' || to_char(pe, 'FMMM/FMDD/YYYY'), '', '', 'Opening', '100'),
        jsonb_build_array('', '', '', 'Payments in', '558.88'),
        jsonb_build_array('', '', '', 'Payments out', '201'),
        jsonb_build_array('', '', '', 'Closing', '457.88'),
        jsonb_build_array(), jsonb_build_array('All Goals'),
        jsonb_build_array('Date', 'Payment type', 'In', 'Out', 'Balance'),
        pg_temp.bd(ps,     'Go & Grow returns', '0.02', '', '100.02'),
        pg_temp.bd(ps + 1, 'SEPA payment', '0.15', '', '100.17'),
        pg_temp.bd(ps + 1, 'Unallocated balance - Liquidity', '0.05', '', '100.17'),
        pg_temp.bd(ps + 2, 'SEPA payment', '500', '', '600.17'),
        pg_temp.bd(ps + 3, 'Go & Grow returns', '8.7100000000000009', '', '608.88'),
        pg_temp.bd(ps + 5, 'SEPA payment', '50', '', '658.88'),
        pg_temp.bd(ps + 9, 'Withdrawal to bank account', '', '201', '457.88'));
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_bb_gg__', 'table', jsonb_build_object('rows', v_grid));

    -- ---------- Vorschau: gedruckter Auszug aus der Datei, kein Owner-Saldo ----------
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [P1 prepare]: %', v_prep; END IF;
    IF v_prep->>'balance_source' <> 'printed' OR (v_prep->>'period_start')::date <> ps OR (v_prep->>'period_end')::date <> pe
       OR (v_prep->>'opening_balance')::numeric <> 100 OR (v_prep->>'closing_balance')::numeric <> 457.88 THEN
        RAISE EXCEPTION 'FAIL [P2 gedruckter Kopf aus der Datei]: %', v_prep;
    END IF;
    IF (SELECT string_agg(m->>'kind' || ':' || ((m->>'amount')::numeric)::text || ':' || COALESCE(m->>'fee', '-'), ',' ORDER BY (m->>'line_date')::date)
        FROM jsonb_array_elements(v_prep->'matched') m)
       IS DISTINCT FROM 'transfer:500.00:-,recurring:50.00:-,transfer:-201.00:1.00' THEN
        RAISE EXCEPTION 'FAIL [P3 Einzahlung/Dauerauftrag/Auszahlung]: %', v_prep->'matched';
    END IF;
    IF (SELECT (m->>'other_account_id')::int FROM jsonb_array_elements(v_prep->'matched') m WHERE m->>'kind' = 'transfer' LIMIT 1) <> v_tr THEN
        RAISE EXCEPTION 'FAIL [P4 Gegenkonto = Verrechnungskonto]: %', v_prep->'matched';
    END IF;
    IF (v_prep->>'interest_correction')::numeric <> 0.70 OR (v_prep->>'legacy_returns')::numeric <> 0.15
       OR jsonb_array_length(v_prep->'interest_skips') <> v_open_before OR v_open_before = 0 THEN
        RAISE EXCEPTION 'FAIL [P5 Zinskorrektur 0.70, Altkredit 0.15, Skips]: % / % / % (offen %)', v_prep->>'interest_correction',
            v_prep->>'legacy_returns', jsonb_array_length(v_prep->'interest_skips'), v_open_before;
    END IF;
    IF (v_prep->>'lump')::numeric <> 0 OR (v_prep->>'unmatched_in')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [P6 Rest 0]: lump % in %', v_prep->>'lump', v_prep->>'unmatched_in';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_interest_correction')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_legacy_returns')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_opening')
       -- Karte = Buchung: die Auszahlung zeigt Transfer -200 und Gebuehr 1 getrennt
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c
                      WHERE c->'value'->>'value' = 'finance.tpl.statement_transfer_fee_row'
                        AND (c->'value'->'params'->'amount'->>'value')::numeric = -200
                        AND (c->'value'->'params'->'fee'->>'value')::numeric = 1) THEN
        RAISE EXCEPTION 'FAIL [P7 Karte]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [P1-P7 Vorschau]';

    -- ---------- Buchung ----------
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [A1 apply]: %', v_app; END IF;
    IF (SELECT balance FROM finance.account_balances WHERE account_id = v_gg) <> 457.88
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_tr) <> 650
       OR (SELECT last_reconciled_at FROM finance.accounts WHERE id = v_gg) <> pe THEN
        RAISE EXCEPTION 'FAIL [A2 Salden]: gg % tr %', (SELECT balance FROM finance.account_balances WHERE account_id = v_gg),
            (SELECT balance FROM finance.account_balances WHERE account_id = v_tr);
    END IF;
    IF (SELECT count(*) FROM finance.transactions f JOIN finance.transactions t ON t.group_id = f.group_id
        WHERE f.account_id = v_gg AND f.category = 'fee' AND f.amount = -1 AND t.account_id = v_tr AND t.amount = 200) <> 1 THEN
        RAISE EXCEPTION 'FAIL [A3 Auszahlung 200 + Gebuehr 1 in einer Gruppe]';
    END IF;
    IF (SELECT count(*) FROM finance.transactions WHERE account_id = v_gg AND category = 'interest' AND interest_period_end IS NULL AND amount = 0.70) <> 1
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_gg AND category = 'other' AND amount = 0.15
           AND description = 'Rückflüsse Bondora-Altkredite') <> 1 THEN
        RAISE EXCEPTION 'FAIL [A4 Zinskorrektur + Altkredit je eine Buchung]';
    END IF;
    IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open(pe) o WHERE o.account_id = v_gg AND o.period_end <= pe) THEN
        RAISE EXCEPTION 'FAIL [A5 offene Zins-Vorkommen uebersprungen]';
    END IF;
    RAISE NOTICE 'PASS [A1-A5 Buchung]';

    -- ---------- TR-Auszug danach: alles schon gebucht ----------
    v_grid := jsonb_build_object('account_name', '__t_bb_tr__', 'currency', 'EUR',
        'period_start', ps, 'period_end', pe, 'opening_balance', 1000, 'closing_balance', 650,
        'lines', jsonb_build_array(
            jsonb_build_object('date', ps + 2, 'amount', -500, 'counterparty', 'Bondora Capital', 'purpose', 'Einzahlung'),
            jsonb_build_object('date', ps + 5, 'amount', -50, 'counterparty', 'Bondora Capital', 'purpose', 'Sparrate'),
            jsonb_build_object('date', ps + 11, 'amount', 200, 'counterparty', 'Go&Grow OU', 'purpose', 'Auszahlung')));
    v_res := finance.fn_statement_prepare(v_grid);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'already_booked') <> 3
       OR jsonb_array_length(v_res->'matched') <> 0 OR (v_res->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [T1 TR erkennt alles als gebucht]: %', v_res;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_grid || jsonb_build_object('fingerprint', v_res->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T2 apply TR]: %', v_app; END IF;
    RAISE NOTICE 'PASS [T1-T2 TR danach]';

    -- ---------- Void: Bondora erst nach TR ----------
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_gg));
    IF v_res->>'code' IS DISTINCT FROM 'partner_reconciled' THEN RAISE EXCEPTION 'FAIL [V1 Void-Schutz]: %', v_res; END IF;
    PERFORM finance.fn_void_bank_statement(jsonb_build_object('account_id', v_tr));
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_gg));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_gg) <> 108.03
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_tr) <> 1000
       OR (SELECT count(*) FROM finance.fn_interest_due_open(pe) o WHERE o.account_id = v_gg AND o.period_end <= pe) <> v_open_before THEN
        RAISE EXCEPTION 'FAIL [V2 alles zurueck inkl. Zins-Skips]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [V1-V2 Void]';

    -- ---------- Ohne Verrechnungskonto: Ein-/Auszahlung im Rest + Hinweis ----------
    v_gg2 := (finance.fn_create_account(jsonb_build_object('name', '__t_bb_gg2__', 'account_type', 'p2p', 'currency', 'EUR',
                 'bank', 'Bondora', 'opening_balance', 100, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_bb_gg2__"}'::jsonb);
    -- Rest = 500 + 50 - 201 (kein Gegenkonto); Zins 8.73 als Korrektur (nichts geschaetzt), Altkredit 0.15
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric <> 349
       OR (v_res->>'interest_correction')::numeric <> 8.73
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'card_lines') c WHERE c->>'value' = 'finance.note.statement_no_settlement') THEN
        RAISE EXCEPTION 'FAIL [N1 ohne Verrechnungskonto]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [N1 ohne Verrechnungskonto]';

    -- ---------- Bank-Import zuerst: Transfer ohne Gebuehr gebucht -> Bondora erkennt ihn (Gruppe + Gebuehr) ----------
    v_res := finance.fn_book_transfer(jsonb_build_object('from_account_id', v_gg2, 'to_account_id', v_tr, 'amount', 200,
                 'transaction_date', (ps + 9)::text, 'from_account_name', '__t_bb_gg2__', 'to_account_name', '__t_bb_tr__'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP gg2 transfer: %', v_res; END IF;
    v_prep := finance.fn_statement_prepare(v_p || '{"account_name":"__t_bb_gg2__"}'::jsonb);
    -- Rest = 500 + 50 (Einzahlungen ohne Gegenkonto); die -201 trifft die 200er-Gruppe, 1 Gebuehr wird nachgebucht
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR (v_prep->>'lump')::numeric <> 550
       OR (SELECT (b->>'fee_add')::numeric FROM jsonb_array_elements(v_prep->'already_booked') b WHERE (b->>'amount')::numeric = -201) IS DISTINCT FROM 1.00
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->'value'->>'value' = 'finance.tpl.statement_transfer_fee_row') THEN
        RAISE EXCEPTION 'FAIL [N2 Gebuehr zu schon gebuchtem Transfer]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('account_name', '__t_bb_gg2__', 'fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_gg2 AND category = 'fee' AND amount = -1 AND group_id IS NULL) <> 1
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_gg2) <> 457.88 THEN
        RAISE EXCEPTION 'FAIL [N3 Gebuehr eigene Buchung, Stand]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [N2-N3 Bank-Import zuerst]';
END $$;
ROLLBACK;
