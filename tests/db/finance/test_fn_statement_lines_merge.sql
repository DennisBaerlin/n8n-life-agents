-- ============================================================
-- test_fn_statement_lines_merge -- Doppelte und Stornos vor der Dauerauftrags-Erkennung entfernen (erfundene Zeilen)
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_in  JSONB;
    v_out JSONB;
BEGIN
    v_in := jsonb_build_array(
        jsonb_build_object('date', '2026-05-03', 'amount', -9.99, 'counterparty', 'Musikdienst Test', 'purpose', 'Abo Mai'),
        -- doppelt (ueberlappender Auszug)
        jsonb_build_object('date', '2026-05-03', 'amount', -9.99, 'counterparty', 'Musikdienst Test', 'purpose', 'Abo Mai'),
        -- zwei echte Zahlungen am selben Tag, anderer Zweck
        jsonb_build_object('date', '2026-05-01', 'amount', -200, 'counterparty', 'Kita Test', 'purpose', 'Kind A'),
        jsonb_build_object('date', '2026-05-01', 'amount', -200, 'counterparty', 'Kita Test', 'purpose', 'Kind B'),
        -- Lastschrift + Ruecklastschrift binnen 14 Tagen
        jsonb_build_object('date', '2026-05-05', 'amount', -42, 'counterparty', 'Fitness Test', 'purpose', 'Beitrag'),
        jsonb_build_object('date', '2026-05-09', 'amount', 42, 'counterparty', 'FITNESS TEST', 'purpose', 'Ruecklastschrift'),
        -- Gegenbuchung nach 20 Tagen ist kein Storno
        jsonb_build_object('date', '2026-05-02', 'amount', -15, 'counterparty', 'Laden Test', 'purpose', 'Kauf'),
        jsonb_build_object('date', '2026-05-22', 'amount', 15, 'counterparty', 'Laden Test', 'purpose', 'Erstattung'),
        -- ohne Gegenpart kein Storno-Paar
        jsonb_build_object('date', '2026-05-10', 'amount', -5, 'counterparty', '', 'purpose', 'x'),
        jsonb_build_object('date', '2026-05-11', 'amount', 5, 'counterparty', '', 'purpose', 'y'));
    v_out := finance.fn_statement_lines_merge(v_in);
    IF jsonb_array_length(v_out) <> 7 THEN
        RAISE EXCEPTION 'FAIL [7 Zeilen bleiben]: %', v_out;
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_out) l WHERE l->>'counterparty' = 'Musikdienst Test') <> 1 THEN
        RAISE EXCEPTION 'FAIL [Doppelte einmal]: %', v_out;
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_out) l WHERE l->>'counterparty' = 'Kita Test') <> 2 THEN
        RAISE EXCEPTION 'FAIL [selber Tag, anderer Zweck bleibt]: %', v_out;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_out) l WHERE lower(l->>'counterparty') = 'fitness test') THEN
        RAISE EXCEPTION 'FAIL [Storno-Paar raus]: %', v_out;
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_out) l WHERE l->>'counterparty' = 'Laden Test') <> 2 THEN
        RAISE EXCEPTION 'FAIL [nach 20 Tagen kein Storno]: %', v_out;
    END IF;
    IF v_out->0->>'date' <> '2026-05-01' THEN
        RAISE EXCEPTION 'FAIL [nach Datum sortiert]: %', v_out;
    END IF;
    IF finance.fn_statement_lines_merge(NULL) <> '[]'::jsonb OR finance.fn_statement_lines_merge('{}'::jsonb) <> '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [kein Array -> leer]';
    END IF;
    RAISE NOTICE 'PASS [fn_statement_lines_merge]';
END $$;
ROLLBACK;
