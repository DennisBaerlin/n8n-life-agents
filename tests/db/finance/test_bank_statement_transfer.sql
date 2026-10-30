-- ============================================================
-- test_bank_statement_transfer -- Ad-hoc-Transfers zwischen eigenen Konten im Monats-Check (Bank-Import-Modul P1)
--   fn_statement_match (Stufe T: Gegen-IBAN = eigenes Konto; Stufe 0 'g:' gegen gebuchte Transfer-Gruppen),
--   fn_statement_prepare (blocked: nicht buchbares Ziel / pending_pair; Monatsgrenze; Rest-Label p2p),
--   fn_apply_bank_statement (fn_book_transfer, Bein-Verschiebung), fn_void_bank_statement (partner_reconciled).
--   Werte erfunden. Zwei Girokonten A/B (Stand 1000 am Vortag des Zeitraums), Depot an A (Kontonummer bekannt),
--   Dauerauftrag A->B (Stufe 0 bleibt 't:'), beide Import-Reihenfolgen, Monatsgrenze, Void-Schutz.
-- ============================================================
BEGIN;
DO $$
DECLARE
    ps   DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe   DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    ps2  DATE;
    pe2  DATE;
    v_a  INT; v_b INT; v_depot INT; v_p2p INT; r_spar INT;
    v_res JSONB; v_prep JSONB; v_app JSONB; v_sa JSONB; v_sb JSONB; v_sp JSONB;
    v_grp UUID;
BEGIN
    ps2 := pe + 1;
    pe2 := (date_trunc('month', pe + 1) + interval '1 month - 1 day')::date;
    -- ---------- Setup ----------
    v_a := (finance.fn_create_account('{"name":"__t_bt_a__","account_type":"cash","currency":"EUR","account_number":"DE11520513735120710131"}'::jsonb)->>'account_id')::int;
    v_b := (finance.fn_create_account('{"name":"__t_bt_b__","account_type":"cash","currency":"EUR","account_number":"DE81520513735120710132"}'::jsonb)->>'account_id')::int;
    v_depot := (finance.fn_create_account(jsonb_build_object('name', '__t_bt_depot__', 'account_type', 'stocks_depot',
                   'currency', 'EUR', 'settlement_id', v_a, 'account_number', 'DEPOT-4711'))->>'account_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 1000, ps - 20, 'other'), (v_b, 1000, ps - 20, 'other');
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 1000, 'reconciliation_date', (ps - 1)::text));
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_b, 'confirmed_balance', 1000, 'reconciliation_date', (ps - 1)::text));
    -- Dauerauftrag A->B am 10., schon von Hand bestaetigt (beide Auszuege treffen ihn ueber Stufe 0 't:', nie 'g:')
    r_spar := finance.fn_add_recurring_payment(v_a, -100, 'Sparrate B', 1::smallint, 'month'::finance.schedule_unit, 10::smallint,
                  (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_b WHERE id = r_spar;
    v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_spar, 'due_date', (ps + 9)::text,
                 'amount', 100, 'transaction_date', (ps + 9)::text));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP spar: %', v_res; END IF;
    -- frueher von Hand gebuchter Ad-hoc-Transfer A->B 75 (ps+12): die Bank zeigt 70 -> nie ein zweiter Transfer (pending_pair)
    v_res := finance.fn_book_transfer(jsonb_build_object('from_account_id', v_a, 'to_account_id', v_b, 'amount', 75,
                 'transaction_date', (ps + 12)::text, 'from_account_name', '__t_bt_a__', 'to_account_name', '__t_bt_b__'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP hand transfer: %', v_res; END IF;

    -- A: -200 an B (Ad-hoc), -100 Sparrate (Dauerauftrag), -50 ans Depot (nicht buchbar), -70 an B (pending_pair),
    --    -30 REWE, -120 an B am letzten Tag (kommt bei B erst im Folgemonat an)
    v_sa := jsonb_build_object('account_name', '__t_bt_a__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 1000, 'closing_balance', 1000 - 200 - 100 - 50 - 70 - 30 - 120,
        'lines', jsonb_build_array(
            jsonb_build_object('date', ps + 3, 'amount', -200, 'counterparty', 'Ich', 'counterparty_iban', 'DE81 5205 1373 5120 7101 32', 'purpose', 'Umbuchung'),
            jsonb_build_object('date', ps + 9, 'amount', -100, 'counterparty', 'Ich', 'counterparty_iban', 'DE81520513735120710132', 'purpose', 'Sparrate'),
            jsonb_build_object('date', ps + 5, 'amount', -50, 'counterparty', 'Depot', 'counterparty_iban', 'depot-4711', 'purpose', 'Depot'),
            jsonb_build_object('date', ps + 13, 'amount', -70, 'counterparty', 'Ich', 'counterparty_iban', 'DE81520513735120710132', 'purpose', 'Rest'),
            jsonb_build_object('date', ps + 18, 'amount', -30, 'counterparty', 'REWE', 'purpose', 'Einkauf'),
            jsonb_build_object('date', pe, 'amount', -120, 'counterparty', 'Ich', 'counterparty_iban', 'DE81520513735120710132', 'purpose', 'Monatsende')));

    -- ---------- T1: Auszug A zuerst ----------
    v_prep := finance.fn_statement_prepare(v_sa);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T1 prepare A]: %', v_prep; END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'matched') m WHERE m->>'kind' = 'transfer'
          AND (m->>'other_account_id')::int = v_b AND (m->>'amount')::numeric IN (-200, -120)) <> 2
       OR jsonb_array_length(v_prep->'matched') <> 2 THEN
        RAISE EXCEPTION 'FAIL [T1a Ad-hoc-Transfers -200/-120 an B]: %', v_prep->'matched';
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'already_booked') b WHERE (b->>'transaction_id')::int IS NOT NULL
          AND b->>'stage' = '0' AND (b->>'amount')::numeric = -100) <> 1 THEN
        RAISE EXCEPTION 'FAIL [T1b Sparrate bleibt Stufe 0 t:]: %', v_prep->'already_booked';
    END IF;
    IF (SELECT string_agg(((b->>'amount')::numeric)::int || ':' || (b->>'reason'), ',' ORDER BY (b->>'amount')::numeric) FROM jsonb_array_elements(v_prep->'blocked') b)
       IS DISTINCT FROM '-70:pending_pair,-50:not_bookable' THEN
        RAISE EXCEPTION 'FAIL [T1c blocked Depot + pending_pair]: %', v_prep->'blocked';
    END IF;
    -- Rest = -30 REWE -50 Depot -70 Rest-Zeile +75 (der von Hand gebuchte 75er steckt im Systemstand, Bank sagt 70 und
    --   es gibt keine Zeile dafuer: die Differenz ist ehrlich Rest) = -75
    IF (v_prep->>'lump')::numeric <> -75 THEN RAISE EXCEPTION 'FAIL [T1d Rest A]: %', v_prep->>'lump'; END IF;
    v_app := finance.fn_apply_bank_statement(v_sa || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T1e apply A]: %', v_app; END IF;
    IF (SELECT balance FROM finance.account_balances WHERE account_id = v_a) <> 430
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_b AND category = 'transfer' AND amount IN (200, 120)) <> 2 THEN
        RAISE EXCEPTION 'FAIL [T1f Salden nach A]: A % ', (SELECT balance FROM finance.account_balances WHERE account_id = v_a);
    END IF;
    RAISE NOTICE 'PASS [T1 Auszug A: Ad-hoc-Transfer, Stufe 0 t:, blocked, Rest]';

    -- B (gleicher Zeitraum): +200 von A (schon gebucht -> Stufe 0 g:), +100 Sparrate (t:), +75 Hand-Transfer (g:);
    --   der +120 von A kommt erst im Folgemonat -> das Bein wird auf pe+1 verschoben, nie Rest
    v_sb := jsonb_build_object('account_name', '__t_bt_b__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 1000, 'closing_balance', 1000 + 200 + 100 + 75,
        'lines', jsonb_build_array(
            jsonb_build_object('date', ps + 4, 'amount', 200, 'counterparty', 'Ich', 'counterparty_iban', 'DE11520513735120710131', 'purpose', 'Umbuchung'),
            jsonb_build_object('date', ps + 10, 'amount', 100, 'counterparty', 'Ich', 'counterparty_iban', 'DE11520513735120710131', 'purpose', 'Sparrate'),
            jsonb_build_object('date', ps + 13, 'amount', 75, 'counterparty', 'Ich', 'counterparty_iban', 'DE11520513735120710131', 'purpose', 'Hand')));
    v_prep := finance.fn_statement_prepare(v_sb);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T2 prepare B]: %', v_prep; END IF;
    IF jsonb_array_length(v_prep->'matched') <> 0 OR jsonb_array_length(v_prep->'already_booked') <> 3 THEN
        RAISE EXCEPTION 'FAIL [T2a alles schon gebucht]: matched % booked %', v_prep->'matched', v_prep->'already_booked';
    END IF;
    IF (v_prep->>'lump')::numeric <> 0 OR jsonb_array_length(v_prep->'moved_legs') <> 1
       OR (v_prep->'moved_legs'->0->>'amount')::numeric <> 120
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_in_transit') THEN
        RAISE EXCEPTION 'FAIL [T2b Rest 0, 120er-Bein verschoben]: lump % moved %', v_prep->>'lump', v_prep->'moved_legs';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_sb || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T2c apply B]: %', v_app; END IF;
    IF (SELECT balance FROM finance.account_balances WHERE account_id = v_b) <> 1495
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = v_b AND amount = 120) <> pe + 1
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = v_a AND amount = -120) <> pe
       OR (SELECT last_reconciled_balance FROM finance.accounts WHERE id = v_b) <> 1375 THEN
        RAISE EXCEPTION 'FAIL [T2d B-Stand + Verschiebung]';
    END IF;
    RAISE NOTICE 'PASS [T2 Auszug B: Stufe 0 g:/t:, Monatsgrenze]';

    -- B Folgemonat: +120 kommt am pe+2 -> trifft das verschobene Bein (g:), kein zweiter Transfer
    v_res := finance.fn_statement_prepare(jsonb_build_object('account_name', '__t_bt_b__', 'currency', 'EUR',
        'period_start', ps2, 'period_end', pe2, 'opening_balance', 1375, 'closing_balance', 1495,
        'lines', jsonb_build_array(jsonb_build_object('date', pe + 2, 'amount', 120, 'counterparty', 'Ich',
                                                      'counterparty_iban', 'DE11520513735120710131'))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'matched') <> 0
       OR jsonb_array_length(v_res->'already_booked') <> 1 OR (v_res->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [T3 Folgemonat trifft das verschobene Bein]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [T3 Folgemonat]';

    -- ---------- T4: Void-Schutz ----------
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_a));
    IF v_res->>'code' IS DISTINCT FROM 'partner_reconciled' OR (v_res->>'ok')::boolean THEN
        RAISE EXCEPTION 'FAIL [T4a A zuruecknehmen trotz abgeglichenem B]: %', v_res;
    END IF;
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_b));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T4b B zuruecknehmen]: %', v_res; END IF;
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_a));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T4c danach A]: %', v_res; END IF;
    IF (SELECT balance FROM finance.account_balances WHERE account_id = v_a) <> 1000 - 100 - 75
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_b) <> 1000 + 100 + 75 THEN
        RAISE EXCEPTION 'FAIL [T4d Ausgangsstand]';
    END IF;
    RAISE NOTICE 'PASS [T4 Void-Schutz]';

    -- ---------- T5: umgekehrte Reihenfolge (B zuerst) ----------
    v_sp := v_sb || jsonb_build_object('closing_balance', 1000 + 200 + 100 + 75);
    v_prep := finance.fn_statement_prepare(v_sp);
    IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'matched') m WHERE m->>'kind' = 'transfer'
          AND (m->>'other_account_id')::int = v_a AND (m->>'amount')::numeric = 200) <> 1 THEN
        RAISE EXCEPTION 'FAIL [T5a B zuerst: Transfer von A]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_sp || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [T5b apply B]: %', v_app; END IF;
    v_prep := finance.fn_statement_prepare(v_sa);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT count(*) FROM jsonb_array_elements(v_prep->'already_booked') b WHERE (b->>'amount')::numeric = -200) <> 1
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'matched') m WHERE (m->>'amount')::numeric = -200) THEN
        RAISE EXCEPTION 'FAIL [T5c A danach: -200 schon gebucht]: %', v_prep;
    END IF;
    -- -120 an B am pe: B ist bis pe abgeglichen (sein Auszug kam zuerst, das Geld dort erst danach) -> unterwegs:
    --   B-Bein ab pe+1, steht auf der Karte; nie blocked/Rest (sonst buchte B's Folgeauszug einen zweiten Transfer)
    IF (SELECT (m->>'partner_date')::date FROM jsonb_array_elements(v_prep->'matched') m WHERE (m->>'amount')::numeric = -120) IS DISTINCT FROM pe + 1
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_in_transit') THEN
        RAISE EXCEPTION 'FAIL [T5d -120 unterwegs, B-Bein ab pe+1]: %', v_prep;
    END IF;
    -- liegt der Abgleich von B mehr als 5 Tage nach der Zeile, ist es kein Unterwegs mehr -> blocked partner_reconciled
    v_res := finance.fn_statement_prepare(v_sa || jsonb_build_object('closing_balance', (v_sa->>'closing_balance')::numeric - 10,
                 'lines', (v_sa->'lines') || jsonb_build_array(jsonb_build_object('date', ps + 1, 'amount', -10,
                     'counterparty', 'Ich', 'counterparty_iban', 'DE81520513735120710132'))));
    IF (SELECT b->>'reason' FROM jsonb_array_elements(v_res->'blocked') b WHERE (b->>'amount')::numeric = -10) IS DISTINCT FROM 'partner_reconciled' THEN
        RAISE EXCEPTION 'FAIL [T5e alt + abgeglichen -> partner_reconciled]: %', v_res->'blocked';
    END IF;
    -- erkannte, nicht buchbare Umbuchung ist kein Alltag (Live-Befund 2026-10-30: -700 an ein spaeter angelegtes Konto
    -- blaehte die Alltags-Schaetzung auf) -> unmatched_out wie ohne die Zeile; der Rest deckt sie weiter ab
    IF (v_res->>'unmatched_out')::numeric IS DISTINCT FROM (v_prep->>'unmatched_out')::numeric
       OR (v_res->>'lump')::numeric IS DISTINCT FROM (v_prep->>'lump')::numeric - 10 THEN
        RAISE EXCEPTION 'FAIL [T5f blocked nicht in unmatched_out, aber im Rest]: out % vs %, lump % vs %',
            v_res->>'unmatched_out', v_prep->>'unmatched_out', v_res->>'lump', v_prep->>'lump';
    END IF;
    v_app :=finance.fn_apply_bank_statement(v_sa || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_b AND category = 'transfer' AND amount = 200) <> 1
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = v_b AND amount = 120) <> pe + 1
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = v_a AND amount = -120) <> pe
       OR (SELECT last_reconciled_balance FROM finance.accounts WHERE id = v_b) <> 1375 THEN
        RAISE EXCEPTION 'FAIL [T5f keine Doppelbuchung, Unterwegs-Bein]: %', v_app;
    END IF;
    -- fn_book_transfer (DB-Gesetz): nie ein Bein in einen bestaetigten Zeitraum
    v_res := finance.fn_book_transfer(jsonb_build_object('from_account_id', v_a, 'to_account_id', v_b, 'amount', 5,
                 'transaction_date', (ps + 2)::text, 'from_account_name', 'a', 'to_account_name', 'b'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [T5g book_transfer in bestaetigten Zeitraum]: %', v_res; END IF;
    RAISE NOTICE 'PASS [T5 umgekehrte Reihenfolge, unterwegs]';

    -- ---------- T6: Rest-Label je Kontoart ----------
    v_p2p := (finance.fn_create_account(jsonb_build_object('name', '__t_bt_p2p__', 'account_type', 'p2p', 'currency', 'EUR',
                  'opening_balance', 500, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_res := finance.fn_statement_prepare(jsonb_build_object('account_name', '__t_bt_p2p__', 'currency', 'EUR',
        'period_start', ps, 'period_end', pe, 'opening_balance', 500, 'closing_balance', 495,
        'lines', jsonb_build_array(jsonb_build_object('date', ps + 1, 'amount', -5, 'purpose', 'x'))));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'card_lines') c WHERE c->>'label' = 'finance.label.statement_other_diff')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'card_lines') c WHERE c->>'label' = 'finance.label.statement_everyday') THEN
        RAISE EXCEPTION 'FAIL [T6 Rest-Label p2p]: %', v_res->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [T6 Rest-Label]';
END $$;
ROLLBACK;
