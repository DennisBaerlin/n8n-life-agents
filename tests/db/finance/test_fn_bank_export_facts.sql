-- ============================================================
-- test_fn_bank_export_facts -- Tabellen-Datei vor dem Modell erkennen (Vorab-Ergebnis fuer agent.finance)
--   finance.fn_bank_export_facts({table}): Datei-Fakten aus fn_bank_export_normalize, das Konto aus fn_bank_export_load
--   (ohne Kontoname). Nur Fakten, die das Modell sonst raten wuerde: Profil, Bank, das Konto bzw. die Kandidaten (Namen),
--   bestaetigt bis (fn_account_confirmed_until), Zeitraum und Zeilenzahl der Datei. Nie Zeilen-Inhalte, nie Space-Namen.
--   Unbekannte Datei -> recognised:false (der Workflow reicht sie unveraendert ans Modell, kein Abbruch).
--   I1 unbekannt; I2 ein Konto; I3 zwei Konten -> Kandidaten; I4 kein Konto; I5 keine Zeilen-Inhalte. Werte erfunden.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.n26(p_d date, p_partner text, p_amt text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text, p_d::text, p_partner, '', 'Presentment', '', 'Hauptkonto', p_amt, '', '', '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["Booking Date","Value Date","Partner Name","Partner Iban","Type","Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"]';
    v_tab  JSONB;
    v_acc  INT;
    v_res  JSONB;
BEGIN
    -- nur die Konten dieses Tests tragen ein Export-Profil
    UPDATE finance.accounts SET status = 'closed' WHERE finance.fn_bank_export_account_profile(id) IS NOT NULL;
    v_tab := jsonb_build_object('rows', jsonb_build_array(v_hdr,
                 pg_temp.n26(T - 12, 'Baeckerei Test', '-12.00'), pg_temp.n26(T - 4, 'Kiosk Test', '-3.50')));

    -- I1: kein bekanntes Profil -> nicht erkannt, kein Fehler
    v_res := finance.fn_bank_export_facts(jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array('["a","b"]'::jsonb, '["1","2"]'::jsonb))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'recognised')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [I1 unbekannt -> recognised false]: %', v_res;
    END IF;

    -- I4: Profil erkannt, noch kein Konto dieser Bank
    v_res := finance.fn_bank_export_facts(jsonb_build_object('table', v_tab));
    IF (v_res->>'recognised')::boolean IS DISTINCT FROM true OR v_res->>'profile' IS DISTINCT FROM 'n26_v1'
       OR v_res->>'bank' IS DISTINCT FROM 'N26' OR v_res->>'account_code' IS DISTINCT FROM 'account_unknown'
       OR v_res->>'account_name' IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [I4 kein Konto]: %', v_res;
    END IF;

    -- I2: genau ein N26-Konto -> Konto, bestaetigt bis (= Startdatum), Zeitraum/Zeilen der Datei
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_bi_n26__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'N26', 'opening_balance', 100, 'opening_balance_date', (T - 30)::text))->>'account_id')::int;
    v_res := finance.fn_bank_export_facts(jsonb_build_object('table', v_tab));
    IF v_res->>'account_name' IS DISTINCT FROM '__t_bi_n26__' OR v_res->>'account_code' IS NOT NULL
       OR (v_res->>'covered_until')::date IS DISTINCT FROM T - 30
       OR (v_res->>'date_from')::date IS DISTINCT FROM T - 12 OR (v_res->>'date_to')::date IS DISTINCT FROM T - 4
       OR (v_res->>'row_count')::int IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FAIL [I2 ein Konto]: %', v_res;
    END IF;

    -- I3: zwei N26-Konten -> kein Konto gewaehlt, beide Namen als Kandidaten
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_bi_n26_b__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'N26', 'opening_balance', 50, 'opening_balance_date', (T - 30)::text));
    v_res := finance.fn_bank_export_facts(jsonb_build_object('table', v_tab));
    IF v_res->>'account_code' IS DISTINCT FROM 'account_ambiguous' OR v_res->>'account_name' IS NOT NULL
       OR (SELECT string_agg(c, ',' ORDER BY c) FROM jsonb_array_elements_text(v_res->'candidates') c)
          IS DISTINCT FROM '__t_bi_n26__,__t_bi_n26_b__' THEN
        RAISE EXCEPTION 'FAIL [I3 Kandidaten]: %', v_res;
    END IF;

    -- I5: keine Zeilen und keine Gegenpart-Namen im Vorab-Ergebnis (es geht ans Modell)
    IF v_res ? 'rows' OR v_res ? 'account_types' OR v_res::text LIKE '%Baeckerei%' OR v_res::text LIKE '%Kiosk%' THEN
        RAISE EXCEPTION 'FAIL [I5 keine Zeilen-Inhalte]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [I1-I5 fn_bank_export_facts]';
END $$;
ROLLBACK;
