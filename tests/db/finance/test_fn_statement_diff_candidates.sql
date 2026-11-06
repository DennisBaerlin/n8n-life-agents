-- ============================================================
-- test_fn_statement_diff_candidates -- Buchungen mit gleichem Betrag wie eine Abweichung des Monats-Checks
--   Einheit: gleiches Konto (beide Vorzeichen, bis period_end + 5), andere eigene Konten (umgekehrtes Vorzeichen, Zeitraum
--   +-5 Tage), Grenze je Ziel, keine Doppelung gleicher Ziele. Durchstich: Eroeffnungsbuchung im Zeitraum wird in
--   prepare und apply als Kandidat des Rests gemeldet; ohne Abweichung keine Kandidaten. Werte erfunden.
-- ============================================================
BEGIN;
DO $$
DECLARE
    ps  DATE := date_trunc('month', CURRENT_DATE - 120)::date;
    pe  DATE := (date_trunc('month', CURRENT_DATE - 120) + interval '1 month - 1 day')::date;
    a INT; b INT;
    i INT;
    r JSONB; v_stmt JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    a := (finance.fn_create_account('{"name":"__t_dc_a__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
    b := (finance.fn_create_account('{"name":"__t_dc_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES
        (a,  300, ps + 2,  'other', 'Eroeffnungssaldo'),
        (a, -300, pe + 5,  'other', 'am Rand'),
        (a,  300, pe + 6,  'other', 'zu spaet'),
        (a,  299, ps + 2,  'other', 'anderer Betrag'),
        (b, -300, ps - 5,  'other', 'Gegenkonto am Rand'),
        (b,  300, ps + 3,  'other', 'gleiches Vorzeichen'),
        (b, -300, ps - 6,  'other', 'Gegenkonto zu alt');

    r := finance.fn_statement_diff_candidates(a, jsonb_build_array(jsonb_build_object('for', 'rest', 'amount', 300)), ps, pe);
    IF jsonb_array_length(r) <> 3
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'description' = 'Eroeffnungssaldo' AND (x->>'amount')::numeric = 300
                      AND x->>'for' = 'rest' AND (x->>'same_account')::boolean AND x->>'account_name' = '__t_dc_a__'
                      AND (x->>'date')::date = ps + 2 AND x->>'category' = 'other' AND (x->>'transaction_id')::int IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'description' = 'am Rand')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'description' = 'Gegenkonto am Rand' AND NOT (x->>'same_account')::boolean AND x->>'account_name' = '__t_dc_b__')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'description' IN ('zu spaet', 'anderer Betrag', 'gleiches Vorzeichen', 'Gegenkonto zu alt')) THEN
        RAISE EXCEPTION 'FAIL [D1 Auswahl]: %', r;
    END IF;

    -- gleiches Ziel nur einmal, Ziel 0 entfaellt, gleicher Betrag unter zweitem Namen liefert nichts doppelt
    r := finance.fn_statement_diff_candidates(a, jsonb_build_array(jsonb_build_object('for', 'rest', 'amount', 300),
             jsonb_build_object('for', 'rest_other', 'amount', 300), jsonb_build_object('for', 'drift', 'amount', 0)), ps, pe);
    IF jsonb_array_length(r) <> 3 OR EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'for' <> 'rest') THEN
        RAISE EXCEPTION 'FAIL [D2 keine Doppelung]: %', r;
    END IF;

    -- Grenze: hoechstens 3 je Ziel
    FOR i IN 1..5 LOOP
        INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES (a, 55, ps + i, 'other', 'viele');
    END LOOP;
    r := finance.fn_statement_diff_candidates(a, jsonb_build_array(jsonb_build_object('for', 'rest', 'amount', 55)), ps, pe);
    IF jsonb_array_length(r) <> 3 THEN RAISE EXCEPTION 'FAIL [D3 Grenze]: %', r; END IF;

    -- keine Ziele -> leere Liste, nie NULL
    r := finance.fn_statement_diff_candidates(a, '[]'::jsonb, ps, pe);
    IF r IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [D4 leer]: %', r; END IF;

    -- was der Auszug schon belegt (Stufe 0), ist kein Kandidat
    r := finance.fn_statement_diff_candidates(a, jsonb_build_array(jsonb_build_object('for', 'rest', 'amount', 299)), ps, pe,
             ARRAY(SELECT id FROM finance.transactions WHERE account_id = a AND amount = 299));
    IF r IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [D4b ausgeschlossen]: %', r; END IF;
    RAISE NOTICE 'PASS [D1-D4b Einheit]';

    -- ---------- Durchstich: Eroeffnungsbuchung im Zeitraum, der Auszug kennt sie nicht ----------
    a := (finance.fn_create_account('{"name":"__t_dc_c__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (a, 1000, ps - 20, 'other');
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', a, 'confirmed_balance', 1000, 'reconciliation_date', (ps - 1)::text));
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES (a, 450, ps + 5, 'other', 'Eroeffnungssaldo (Import)');
    v_stmt := jsonb_build_object('account_name', '__t_dc_c__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 1000, 'closing_balance', 1000, 'lines', '[]'::jsonb);
    v_prep := finance.fn_statement_prepare(v_stmt);
    IF (v_prep->>'lump')::numeric <> -450 OR jsonb_array_length(v_prep->'difference_candidates') <> 1
       OR v_prep->'difference_candidates'->0->>'for' <> 'unexplained'
       OR v_prep->'difference_candidates'->0->>'description' <> 'Eroeffnungssaldo (Import)' THEN
        RAISE EXCEPTION 'FAIL [D5 Vorschau]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_app->'difference_candidates') <> 1
       OR (v_app->'difference_candidates'->0->>'amount')::numeric <> 450
       OR (v_app->>'rest_unexplained')::numeric <> -450 THEN
        RAISE EXCEPTION 'FAIL [D6 Rueckgabe]: %', v_app;
    END IF;

    -- keine Abweichung -> keine Kandidaten
    a := (finance.fn_create_account('{"name":"__t_dc_d__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (a, 1000, ps - 20, 'other');
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', a, 'confirmed_balance', 1000, 'reconciliation_date', (ps - 1)::text));
    v_prep := finance.fn_statement_prepare(v_stmt || '{"account_name":"__t_dc_d__"}'::jsonb);
    IF v_prep->'difference_candidates' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [D7 ohne Abweichung]: %', v_prep; END IF;
    RAISE NOTICE 'PASS [D5-D7 Durchstich]';
END $$;
ROLLBACK;
