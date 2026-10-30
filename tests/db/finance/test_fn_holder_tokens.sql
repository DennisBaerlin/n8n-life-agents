-- ============================================================
-- test_fn_holder_tokens -- Normalform gedruckter Namen (fn_match_household_holder). Namen erfunden.
-- ============================================================
BEGIN;
DO $$
BEGIN
    IF finance.fn_holder_tokens('ZWEISTEIN, Maximilian', 1) <> '{maximilian,zweistein}'::text[] THEN
        RAISE EXCEPTION 'FAIL [T1 Kleinschrift, Komma, sortiert]: %', finance.fn_holder_tokens('ZWEISTEIN, Maximilian', 1);
    END IF;
    IF finance.fn_holder_tokens('Jörg Brückner-Maß', 1) <> '{brueckner,joerg,mass}'::text[]
       OR finance.fn_holder_tokens('Jörg Brückner-Maß', 2) <> '{bruckner,jorg,mass}'::text[] THEN
        RAISE EXCEPTION 'FAIL [T2 Umlaut-Varianten + ss]: % / %', finance.fn_holder_tokens('Jörg Brückner-Maß', 1),
            finance.fn_holder_tokens('Jörg Brückner-Maß', 2);
    END IF;
    IF finance.fn_holder_tokens('François Núñez Ibáñez Löw Ølund', 2) <> '{francois,ibanez,low,lund,nunez}'::text[] THEN
        RAISE EXCEPTION 'FAIL [T3 Akzente (c, n, u, a, o)]: %', finance.fn_holder_tokens('François Núñez Ibáñez Löw Ølund', 2);
    END IF;
    IF finance.fn_holder_tokens('Herr Dr. M. Zweistein und Frau E. Zweistein', 1) <> '{zweistein}'::text[] THEN
        RAISE EXCEPTION 'FAIL [T4 Anrede, Initialen, Fuellwoerter, Dubletten]: %',
            finance.fn_holder_tokens('Herr Dr. M. Zweistein und Frau E. Zweistein', 1);
    END IF;
    IF finance.fn_holder_tokens(NULL, 1) <> '{}'::text[] OR finance.fn_holder_tokens('  ', 1) <> '{}'::text[] THEN
        RAISE EXCEPTION 'FAIL [T5 NULL/leer]';
    END IF;
    RAISE NOTICE 'PASS [T1-T5 fn_holder_tokens]';
END $$;
ROLLBACK;
