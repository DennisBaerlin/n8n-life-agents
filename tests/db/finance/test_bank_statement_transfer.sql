-- ============================================================
-- test_bank_statement_transfer -- Ad-hoc-Transfers zwischen eigenen Konten im Monats-Check
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
    -- erkannte, nicht buchbare Umbuchung ist kein Alltag (ein Uebertrag an ein spaeter angelegtes Konto
    -- blaehte sonst die Alltags-Schaetzung auf) -> unmatched_out wie ohne die Zeile; der Rest deckt sie weiter ab
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

-- ============================================================
-- Ueberweisung vor dem Eroeffnungstag des Gegenkontos: das Geld steckt dort schon im Startbetrag,
-- gebucht wird nur das Bein des importierten Kontos. Stichtag der spaeter eroeffneten Konten = heute-20, Werte erfunden.
-- ============================================================
CREATE FUNCTION pg_temp.ob_acct(p_name text, p_number text, p_open numeric, p_date date) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_r JSONB;
BEGIN
    v_r := finance.fn_create_account(jsonb_build_object('name', p_name, 'account_type', 'cash', 'currency', 'EUR',
               'account_number', p_number, 'opening_balance', p_open, 'opening_balance_date', p_date::text));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP %: %', p_name, v_r; END IF;
    RETURN (v_r->>'account_id')::int;
END $$;
-- gedruckter Auszug: Endsaldo = Anfang + Summe der Zeilen
CREATE FUNCTION pg_temp.ob_stmt(p_acct text, p_ps date, p_pe date, p_open numeric, p_lines jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('account_name', p_acct, 'currency', 'EUR', 'period_start', p_ps, 'period_end', p_pe,
        'opening_balance', p_open,
        'closing_balance', p_open + COALESCE((SELECT sum((l->>'amount')::numeric) FROM jsonb_array_elements(p_lines) l), 0),
        'lines', p_lines);
$$;
CREATE FUNCTION pg_temp.ob_ln(p_d date, p_amt numeric, p_iban text, p_extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('date', p_d, 'amount', p_amt, 'counterparty', 'Ich', 'counterparty_iban', p_iban, 'purpose', 'Umbuchung') || p_extra;
$$;
CREATE FUNCTION pg_temp.ob_bal(p_id int) RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT balance FROM finance.account_balances WHERE account_id = p_id;
$$;
CREATE FUNCTION pg_temp.ob_note(p_prep jsonb, p_key text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT c FROM jsonb_array_elements(p_prep->'card_lines') c WHERE c->>'value' = p_key LIMIT 1;
$$;

-- ---------- O1: Abgang vor dem Eroeffnungstag des Ziels: nur das Quell-Bein, Karten-Hinweis, Rueckgabe ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_g INT; v_z INT; v_s JSONB; v_prep JSONB; v_app JSONB; v_note JSONB;
BEGIN
    v_g := pg_temp.ob_acct('__t_ob1_g__', 'OB1-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob1_z__', 'OB1-ZIEL', 300, T - 20);
    v_s := pg_temp.ob_stmt('__t_ob1_g__', T - 40, T - 10, 5000, jsonb_build_array(pg_temp.ob_ln(T - 25, -100, 'OB1-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'blocked') <> 0
       OR (v_prep->'matched'->0->>'other_in_opening')::boolean IS DISTINCT FROM true
       OR (v_prep->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [OB1a Treffer mit other_in_opening, Rest 0]: %', v_prep;
    END IF;
    v_note := pg_temp.ob_note(v_prep, 'finance.note.statement_transfer_in_opening');
    IF v_note IS NULL OR v_note->'params'->>'account' IS DISTINCT FROM '__t_ob1_z__'
       OR (v_note->'params'->'amount'->>'value')::numeric IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FAIL [OB1b Karte nennt Konto und Betrag]: %', v_prep->'card_lines';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [OB1c apply]: %', v_app; END IF;
    IF pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 300
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_z AND category = 'transfer')
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_g AND category = 'transfer' AND amount = -100
             AND bank_statement_id = (v_app->>'statement_id')::int AND group_id IS NOT NULL) <> 1 THEN
        RAISE EXCEPTION 'FAIL [OB1d Quelle belastet, Ziel unveraendert]: g % z %', pg_temp.ob_bal(v_g), pg_temp.ob_bal(v_z);
    END IF;
    IF jsonb_array_length(v_app->'transfers') <> 1 OR v_app->'transfers'->0->>'account_name' IS DISTINCT FROM '__t_ob1_z__'
       OR (v_app->'transfers'->0->>'amount')::numeric IS DISTINCT FROM -100
       OR (v_app->'transfers'->0->>'fee')::numeric IS DISTINCT FROM 0
       OR (v_app->'transfers'->0->>'other_in_opening')::boolean IS DISTINCT FROM true
       OR (v_app->>'booked_count')::int IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FAIL [OB1e transfers nennt das Gegenkonto]: %', v_app;
    END IF;
    -- Void entfernt das eine Bein, erneuter Import bucht es einmal
    v_app := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_g));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 5000
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_g AND category = 'transfer') THEN
        RAISE EXCEPTION 'FAIL [OB1f Void]: %', v_app;
    END IF;
    v_prep := finance.fn_statement_prepare(v_s);
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 300
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_g AND category = 'transfer') <> 1 THEN
        RAISE EXCEPTION 'FAIL [OB1g erneuter Import einmal]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [OB1 Einzelbein, Karte, Void, erneuter Import]';
END $$;

-- ---------- OB2 Durchstich: danach die Datei des Zielkontos, der Rest enthaelt den Betrag nicht ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_hdr JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_g INT; v_z INT; v_res JSONB; v_s JSONB; v_prep JSONB; v_p JSONB;
BEGIN
    v_g := pg_temp.ob_acct('__t_ob2_g__', 'OB2-GIRO', 5000, T - 120);
    v_res := finance.fn_create_account(jsonb_build_object('name', '__t_ob2_z__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'account_number', 'OB2-ZIEL', 'opening_balance', 300, 'opening_balance_date', (T - 20)::text));
    v_z := (v_res->>'account_id')::int;
    v_s := pg_temp.ob_stmt('__t_ob2_g__', T - 40, T - 10, 5000, jsonb_build_array(pg_temp.ob_ln(T - 25, -100, 'OB2-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    v_res := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [OB2a apply Giro]: %', v_res; END IF;
    -- Export des Zielkontos: Eingang vor dem Stichtag (steckt im Startbetrag), Kartenzahlung danach; App-Stand 270
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_ob2_z__', 'closing_balance', '270',
        'table', jsonb_build_object('rows', jsonb_build_array(v_hdr,
            jsonb_build_array((T - 25)::text || 'T10:00:00Z', (T - 25)::text, 'DEFAULT', 'CASH', 'CUSTOMER_INBOUND', '', '', '', '', '', '100.000000', '', '', 'EUR', '', '', '', 'Umbuchung', 'ob2-1', '', '', '', ''),
            jsonb_build_array((T - 10)::text || 'T10:00:00Z', (T - 10)::text, 'DEFAULT', 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-30.000000', '', '', 'EUR', '', '', '', 'Einkauf', 'ob2-2', '', '', '', ''))));
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [OB2b prepare Ziel]: %', v_prep; END IF;
    IF (v_prep->>'lump')::numeric <> -30 OR (v_prep->>'export_gap')::numeric <> 0 OR (v_prep->>'unmatched_out')::numeric <> -30
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_everyday') THEN
        RAISE EXCEPTION 'FAIL [OB2c Rest ohne den Betrag]: lump % gap %', v_prep->>'lump', v_prep->>'export_gap';
    END IF;
    v_res := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_z) <> 270 OR pg_temp.ob_bal(v_g) <> 4900 THEN
        RAISE EXCEPTION 'FAIL [OB2d Staende]: %', v_res;
    END IF;
    IF (v_res->>'export_gap')::numeric IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [OB2e export_gap in der Rueckgabe]: %', v_res; END IF;
    RAISE NOTICE 'PASS [OB2 Durchstich]';
END $$;

-- ---------- OB3 Ziel schon abgeglichen, Zeile vor dessen Stichtag: gebucht, nicht blocked ----------
-- ---------- OB4 Eingang, dessen Quellkonto spaeter eroeffnet wurde: nur das eigene Bein ----------
-- ---------- OB5 Zeile nach dem Stichtag: unveraendert zwei Beine ----------
-- ---------- OB6 Anlage am selben Tag beim Import: zwei Beine ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_g INT; v_z INT; v_q INT; v_h INT; v_s JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    v_g := pg_temp.ob_acct('__t_ob3_g__', 'OB3-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob3_z__', 'OB3-ZIEL', 300, T - 20);
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_z, 'confirmed_balance', 300, 'reconciliation_date', (T - 5)::text));
    v_s := pg_temp.ob_stmt('__t_ob3_g__', T - 40, T - 10, 5000, jsonb_build_array(pg_temp.ob_ln(T - 25, -100, 'OB3-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF jsonb_array_length(v_prep->'blocked') <> 0 OR (v_prep->'matched'->0->>'other_in_opening')::boolean IS DISTINCT FROM true
       OR v_prep->'matched'->0 ? 'partner_date' OR v_prep->'matched'->0 ? 'partner_lump' THEN
        RAISE EXCEPTION 'FAIL [OB3a nicht blocked]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 300 THEN
        RAISE EXCEPTION 'FAIL [OB3b gebucht, Ziel unveraendert]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [OB3 abgeglichenes Ziel]';

    v_h := pg_temp.ob_acct('__t_ob4_h__', 'OB4-HABEN', 5000, T - 120);
    v_q := pg_temp.ob_acct('__t_ob4_q__', 'OB4-QUELLE', 700, T - 20);
    v_s := pg_temp.ob_stmt('__t_ob4_h__', T - 40, T - 10, 5000, jsonb_build_array(pg_temp.ob_ln(T - 25, 100, 'OB4-QUELLE')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->'matched'->0->>'other_in_opening')::boolean IS DISTINCT FROM true OR (v_prep->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [OB4a Treffer]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_h) <> 5100 OR pg_temp.ob_bal(v_q) <> 700
       OR jsonb_array_length(v_app->'transfers') <> 1 OR v_app->'transfers'->0->>'account_name' IS DISTINCT FROM '__t_ob4_q__'
       OR (v_app->'transfers'->0->>'amount')::numeric IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FAIL [OB4b nur das eigene Bein, transfers nennt Betrag und Konto]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [OB4 umgekehrte Richtung]';

    v_g := pg_temp.ob_acct('__t_ob5_g__', 'OB5-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob5_z__', 'OB5-ZIEL', 300, T - 20);
    v_s := pg_temp.ob_stmt('__t_ob5_g__', T - 40, T - 10, 5000, jsonb_build_array(pg_temp.ob_ln(T - 15, -100, 'OB5-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF v_prep->'matched'->0 ? 'other_in_opening' OR pg_temp.ob_note(v_prep, 'finance.note.statement_transfer_in_opening') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [OB5a kein Flag]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 400
       OR (v_app->'transfers'->0->>'other_in_opening')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [OB5b zwei Beine]: %', v_app; END IF;
    RAISE NOTICE 'PASS [OB5 nach dem Stichtag]';

    v_g := pg_temp.ob_acct('__t_ob6_g__', 'OB6-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob6_z__', 'OB6-ZIEL', 300, T);
    v_s := pg_temp.ob_stmt('__t_ob6_g__', T - 40, T, 5000, jsonb_build_array(pg_temp.ob_ln(T, -100, 'OB6-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF v_prep->'matched'->0 ? 'other_in_opening' THEN RAISE EXCEPTION 'FAIL [OB6a kein Flag]: %', v_prep; END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 400 THEN RAISE EXCEPTION 'FAIL [OB6b zwei Beine]: %', v_app; END IF;
    RAISE NOTICE 'PASS [OB6 Anlage am selben Tag]';
END $$;

-- ---------- OB7 Abgang am Stichtag, Ankunft danach, in beiden Import-Reihenfolgen: je Konto genau ein Bein ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_g INT; v_z INT; v_s JSONB; v_sz JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    -- Reihenfolge A: erst die Quelle (Einzelbein), dann das Ziel: seine Zeile findet das Einzelbein -> nie ein zweiter Abgang
    v_g := pg_temp.ob_acct('__t_ob7a_g__', 'OB7A-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob7a_z__', 'OB7A-ZIEL', 300, T - 20);
    v_s := pg_temp.ob_stmt('__t_ob7a_g__', T - 40, T - 10, 5000, jsonb_build_array(pg_temp.ob_ln(T - 20, -100, 'OB7A-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->'matched'->0->>'other_in_opening')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [OB7a am Stichtag = im Startbetrag]: %', v_prep; END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    v_sz := pg_temp.ob_stmt('__t_ob7a_z__', T - 19, T - 5, 300, jsonb_build_array(pg_temp.ob_ln(T - 19, 100, 'OB7A-GIRO')));
    v_prep := finance.fn_statement_prepare(v_sz);
    IF jsonb_array_length(v_prep->'matched') <> 0 OR (SELECT b->>'reason' FROM jsonb_array_elements(v_prep->'blocked') b) IS DISTINCT FROM 'pending_pair'
       OR (v_prep->>'lump')::numeric <> 100 THEN
        RAISE EXCEPTION 'FAIL [OB7b Ziel erkennt das Einzelbein]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_sz || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 400
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_g AND category = 'transfer') <> 1 THEN
        RAISE EXCEPTION 'FAIL [OB7c je Konto ein Bein, Reihenfolge A]: g % z %', pg_temp.ob_bal(v_g), pg_temp.ob_bal(v_z);
    END IF;
    RAISE NOTICE 'PASS [OB7 Reihenfolge A]';

    -- Reihenfolge B: erst das Ziel (bucht beide Beine am Ankunftstag), dann die Quelle: Stufe 0
    v_g := pg_temp.ob_acct('__t_ob7b_g__', 'OB7B-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob7b_z__', 'OB7B-ZIEL', 300, T - 20);
    v_sz := pg_temp.ob_stmt('__t_ob7b_z__', T - 19, T - 5, 300, jsonb_build_array(pg_temp.ob_ln(T - 19, 100, 'OB7B-GIRO')));
    v_prep := finance.fn_statement_prepare(v_sz);
    v_app := finance.fn_apply_bank_statement(v_sz || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [OB7d apply Ziel]: %', v_app; END IF;
    v_s := pg_temp.ob_stmt('__t_ob7b_g__', T - 40, T - 10, 5000, jsonb_build_array(pg_temp.ob_ln(T - 20, -100, 'OB7B-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF jsonb_array_length(v_prep->'already_booked') <> 1 OR jsonb_array_length(v_prep->'matched') <> 0 THEN
        RAISE EXCEPTION 'FAIL [OB7e Quelle erkennt die Gruppe]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 400
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_g AND category = 'transfer') <> 1
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_z AND category = 'transfer') <> 1 THEN
        RAISE EXCEPTION 'FAIL [OB7f je Konto ein Bein, Reihenfolge B]: g % z %', pg_temp.ob_bal(v_g), pg_temp.ob_bal(v_z);
    END IF;
    RAISE NOTICE 'PASS [OB7 Reihenfolge B]';
END $$;

-- ---------- OB8 Auszahlung mit Gebuehr auf diesem Konto: Gebuehr in derselben Gruppe; Flag im Fingerprint ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_g INT; v_z INT; v_s JSONB; v_prep JSONB; v_later JSONB; v_app JSONB; v_grp UUID;
BEGIN
    v_g := pg_temp.ob_acct('__t_ob8_g__', 'OB8-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob8_z__', 'OB8-ZIEL', 300, T - 20);
    v_s := pg_temp.ob_stmt('__t_ob8_g__', T - 40, T - 10, 5000,
        jsonb_build_array(pg_temp.ob_ln(T - 25, -101, 'OB8-ZIEL', '{"transfer_fee": 1}'::jsonb)));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->'matched'->0->>'fee')::numeric IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [OB8a Gebuehr]: %', v_prep->'matched'; END IF;
    -- Stichtag frueher als die Zeile: dieselbe Zeile, aber zwei Beine -> die Vorschau darf nicht mehr gelten
    UPDATE finance.accounts SET opening_balance_date = T - 30 WHERE id = v_z;
    v_later := finance.fn_statement_prepare(v_s);
    IF v_later->'matched'->0 ? 'other_in_opening' OR v_later->>'fingerprint' = v_prep->>'fingerprint' THEN
        RAISE EXCEPTION 'FAIL [OB8b Fingerprint enthaelt other_in_opening]: %', v_later->'matched';
    END IF;
    UPDATE finance.accounts SET opening_balance_date = T - 20 WHERE id = v_z;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4899 OR pg_temp.ob_bal(v_z) <> 300 THEN
        RAISE EXCEPTION 'FAIL [OB8c Staende]: %', v_app;
    END IF;
    SELECT group_id INTO v_grp FROM finance.transactions WHERE account_id = v_g AND category = 'transfer';
    IF v_grp IS NULL OR (SELECT count(*) FROM finance.transactions WHERE group_id = v_grp AND account_id = v_g
                           AND ((category = 'fee' AND amount = -1) OR (category = 'transfer' AND amount = -100))) <> 2
       OR (v_app->'transfers'->0->>'fee')::numeric IS DISTINCT FROM 1 OR v_app->'transfers'->0->>'fee_account' IS DISTINCT FROM 'this' THEN
        RAISE EXCEPTION 'FAIL [OB8d Gebuehr in derselben Gruppe]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [OB8 Gebuehr + Fingerprint]';
END $$;

-- ---------- OB9 Stufe L (IBAN-Lernen): gleiches Verhalten ----------
INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__t_ob9__', 'Erika Mustermann', 'owner')
ON CONFLICT (person_id) DO UPDATE SET full_name = excluded.full_name;
DO $$
DECLARE
    T DATE := core.fn_today();
    v_g INT; v_z INT; v_r JSONB; v_s JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    UPDATE finance.accounts SET status = 'closed' WHERE name LIKE '__t_%' AND account_type = 'cash' AND account_number IS NULL;
    v_r := finance.fn_create_account(jsonb_build_object('name', '__t_ob9_g__', 'account_type', 'cash', 'currency', 'EUR',
               'owner_person_id', '__t_ob9__', 'account_number', 'OB9-GIRO', 'opening_balance', 5000, 'opening_balance_date', (T - 120)::text));
    v_g := (v_r->>'account_id')::int;
    v_r := finance.fn_create_account(jsonb_build_object('name', '__t_ob9_z__', 'account_type', 'cash', 'currency', 'EUR',
               'owner_person_id', '__t_ob9__', 'opening_balance', 300, 'opening_balance_date', (T - 20)::text));
    v_z := (v_r->>'account_id')::int;
    v_s := jsonb_build_object('account_name', '__t_ob9_g__', 'currency', 'EUR', 'period_start', T - 40, 'period_end', T - 10,
        'opening_balance', 5000, 'closing_balance', 4900, 'lines', jsonb_build_array(jsonb_build_object('date', T - 25, 'amount', -100,
            'counterparty', 'Erika Mustermann', 'counterparty_iban', 'DE02 1001 0010 0006 8201 01', 'purpose', 'Umbuchung')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->'matched'->0->>'stage') IS DISTINCT FROM 'L' OR (v_prep->'matched'->0->>'other_in_opening')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [OB9a Stufe L mit Flag]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 300
       OR (SELECT account_number FROM finance.accounts WHERE id = v_z) IS DISTINCT FROM 'DE02100100100006820101' THEN
        RAISE EXCEPTION 'FAIL [OB9b Staende + gelernte IBAN]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [OB9 Stufe L]';
END $$;

-- ---------- OB11 spaete Export-Zeile: zaehlt fuer die Regel mit ihrem echten Buchungstag, nicht mit dem Tag nach dem Schnitt ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_hdr JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_early JSONB; v_late JSONB; v_r JSONB; v_g INT; v_z INT; v_p JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    v_r := finance.fn_create_account(jsonb_build_object('name', '__t_ob11_g__', 'account_type', 'cash', 'currency', 'EUR',
               'bank', 'Trade Republic', 'account_number', 'OB11-GIRO', 'opening_balance', 5000, 'opening_balance_date', (T - 60)::text));
    v_g := (v_r->>'account_id')::int;
    v_z := pg_temp.ob_acct('__t_ob11_z__', 'OB11-ZIEL', 300, T - 12);
    v_early := jsonb_build_array((T - 40)::text || 'T10:00:00Z', (T - 40)::text, 'DEFAULT', 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-10.000000', '', '', 'EUR', '', '', '', 'Laden', 'ob11-1', '', '', '', '');
    v_late := jsonb_build_array((T - 15)::text || 'T10:00:00Z', (T - 15)::text, 'DEFAULT', 'CASH', 'CUSTOMER_OUTBOUND_REQUEST', '', '', '', '', '', '-100.000000', '', '', 'EUR', '', '', '', 'Umbuchung', 'ob11-2', '', 'OB11-ZIEL', '', '');
    -- erster Export ohne die spaete Zeile, Schnitt auf heute-10 nachgestellt (wie C20)
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_ob11_g__', 'closing_balance', '4990',
               'table', jsonb_build_object('rows', jsonb_build_array(v_hdr, v_early)));
    v_prep := finance.fn_statement_prepare(v_p);
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP OB11: %', v_app; END IF;
    UPDATE finance.bank_statements SET period_end = T - 10 WHERE id = (v_app->>'statement_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 10 WHERE id = v_g;
    -- Folge-Export: Zeile vom heute-15 taucht erst jetzt auf -> Datum heute-9, der echte Tag liegt im Startbetrag des Ziels
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_ob11_g__', 'closing_balance', '4890',
               'table', jsonb_build_object('rows', jsonb_build_array(v_hdr, v_early, v_late)));
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR (v_prep->>'late_count')::int <> 1
       OR (v_prep->'matched'->0->>'other_in_opening')::boolean IS DISTINCT FROM true
       OR (v_prep->'matched'->0->>'line_date')::date IS DISTINCT FROM T - 9 THEN
        RAISE EXCEPTION 'FAIL [OB11a spaete Zeile im Startbetrag]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4890 OR pg_temp.ob_bal(v_z) <> 300
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_z AND category = 'transfer') THEN
        RAISE EXCEPTION 'FAIL [OB11b nur das eigene Bein]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [OB11 spaete Zeile]';
END $$;

-- ---------- OB10 Dauerauftrag mit Zeile vor dem Stichtag des Gegenkontos: blocked, Grund auf der Karte ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_d DATE := core.fn_today() - 25;
    v_g INT; v_z INT; v_rp INT; v_s JSONB; v_prep JSONB; v_app JSONB; v_note JSONB;
BEGIN
    WHILE extract(day FROM v_d) > 28 LOOP v_d := v_d - 1; END LOOP;
    v_g := pg_temp.ob_acct('__t_ob10_g__', 'OB10-GIRO', 5000, T - 120);
    v_z := pg_temp.ob_acct('__t_ob10_z__', 'OB10-ZIEL', 300, T - 20);
    v_rp := finance.fn_add_recurring_payment(v_g, -100, '__t_ob10_rate__', 1::smallint, 'month'::finance.schedule_unit,
                extract(day FROM v_d)::smallint, v_d, v_d, NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_z WHERE id = v_rp;
    v_s := pg_temp.ob_stmt('__t_ob10_g__', T - 40, T - 21, 5000, jsonb_build_array(pg_temp.ob_ln(v_d, -100, 'OB10-ZIEL')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF jsonb_array_length(v_prep->'matched') <> 0 OR jsonb_array_length(v_prep->'blocked') <> 1
       OR v_prep->'blocked'->0->>'reason' IS DISTINCT FROM 'partner_in_opening'
       OR (v_prep->>'unmatched_out')::numeric <> 0 OR (v_prep->>'lump')::numeric <> -100 THEN
        RAISE EXCEPTION 'FAIL [OB10a blocked partner_in_opening]: %', v_prep;
    END IF;
    v_note := pg_temp.ob_note(v_prep, 'finance.note.statement_partner_in_opening');
    IF v_note IS NULL OR v_note->'params'->>'account' IS DISTINCT FROM '__t_ob10_z__'
       OR (v_note->'params'->'amount'->>'value')::numeric IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FAIL [OB10b Karte nennt den Grund]: %', v_prep->'card_lines';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_rest_net') THEN
        RAISE EXCEPTION 'FAIL [OB10c Label Rest]: %', v_prep->'card_lines';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.ob_bal(v_g) <> 4900 OR pg_temp.ob_bal(v_z) <> 300 THEN
        RAISE EXCEPTION 'FAIL [OB10d Staende]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [OB10 Dauerauftrag blocked]';
END $$;
ROLLBACK;
