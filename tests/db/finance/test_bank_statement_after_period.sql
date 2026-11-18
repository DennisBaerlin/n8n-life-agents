-- ============================================================
-- test_bank_statement_after_period -- Datei-Import mit Zeilen vom Importtag: der Ausgang trennt die zwei Tage
--   fn_apply_bank_statement (source:'file', N26-Profil, App-Kontostand des Owners). Der Zeitraum endet gestern, die
--   Zeile von heute bucht erst der naechste Export. Der Ausgang muss beide Tage nennen, damit das Modell nie den
--   gebuchten Stand (gestern) mit der Owner-Zahl (heute) vergleicht: period_end (schon im Ausgang der Kette),
--   balance_at_period_end = bestaetigter Stand, after_period = Summe der Datei-Zeilen danach (DB-Rechnung der Prepare).
--   Die App-Zahl selbst kommt nicht zurueck (kein Echo einer Eingabe). Gedruckter Auszug: after_period = 0.
--   Werte erfunden, Daten relativ zu core.fn_today().
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.n26_row(p_d date, p_partner text, p_type text, p_amt text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text, p_d::text, p_partner, '', p_type, '', 'Hauptkonto', p_amt, '', '', '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["Booking Date","Value Date","Partner Name","Partner Iban","Type","Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"]';
    v_acc  INT;
    v_p    JSONB;
    v_prep JSONB;
    v_app  JSONB;
BEGIN
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_ap_n26__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'N26', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    IF v_acc IS NULL THEN RAISE EXCEPTION 'SETUP account'; END IF;

    -- Zeitraum heute-19..gestern: -30 -> Stand gestern 970; heute -10 (Importtag) -> die App zeigt 960
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_ap_n26__', 'closing_balance', '960,00',
                              'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || jsonb_build_array(
                                  pg_temp.n26_row(T - 10, 'Baeckerei Test', 'Presentment', '-30.00'),
                                  pg_temp.n26_row(T, 'Kiosk Heute', 'Presentment', '-10.00'))));

    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR (v_prep->>'closing_balance')::numeric <> 970
       OR (v_prep->>'after_period')::numeric <> -10 THEN
        RAISE EXCEPTION 'FAIL [AP1 Vorschau: Stand gestern 970, Zeile von heute -10]: %', v_prep;
    END IF;

    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [AP2 apply]: %', v_app; END IF;
    -- Bestand: gebuchter Stand heute = Stand gestern (die Zeile von heute ist nicht gebucht)
    IF (v_app->>'balance_after')::numeric IS DISTINCT FROM 970 THEN
        RAISE EXCEPTION 'FAIL [AP3 balance_after = 970]: %', v_app->>'balance_after';
    END IF;
    -- Neu: Stand am period_end und die Zeilen danach im Ausgang, jede Zahl aus der DB
    IF (v_app->>'balance_at_period_end')::numeric IS DISTINCT FROM 970 THEN
        RAISE EXCEPTION 'FAIL [AP4 balance_at_period_end = 970]: %', v_app->>'balance_at_period_end';
    END IF;
    IF (v_app->>'after_period')::numeric IS DISTINCT FROM -10 THEN
        RAISE EXCEPTION 'FAIL [AP5 after_period = -10]: %', v_app->>'after_period';
    END IF;
    IF v_app ? 'owner_balance' THEN
        RAISE EXCEPTION 'FAIL [AP6 kein Echo der App-Zahl]: %', v_app->>'owner_balance';
    END IF;
    RAISE NOTICE 'PASS [AP1-AP6 Datei-Import trennt Stand gestern und Zeilen von heute]';
END $$;
ROLLBACK;
