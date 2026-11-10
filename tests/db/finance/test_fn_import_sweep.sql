-- ============================================================
-- test_fn_import_sweep -- Hygiene: verfallene, nicht committete Staging-Zeilen weg, committete und frische bleiben
--   Gesetz: status <> 'committed' AND created_at < now() - p_days. Rueckgabe = Zahl geloeschter Zeilen.
--   Die Testtransaktion leert import_staging vorab (ROLLBACK am Ende), damit die Zaehlung exakt ist.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_batch_old   UUID := gen_random_uuid();
    v_batch_keep  UUID := gen_random_uuid();
    v_batch_fresh UUID := gen_random_uuid();
    v_n           INT;
BEGIN
    DELETE FROM finance.import_staging;

    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, status, created_at) VALUES
        (v_batch_old,   1, 'account', 'staged',    now() - interval '10 days'),
        (v_batch_old,   2, 'account', 'invalid',   now() - interval '10 days'),
        (v_batch_old,   3, 'account', 'valid',     now() - interval '40 days'),
        (v_batch_keep,  1, 'account', 'committed', now() - interval '10 days'),
        (v_batch_fresh, 1, 'account', 'staged',    now() - interval '1 day'),
        (v_batch_fresh, 2, 'account', 'valid',     now());

    -- Default 7 Tage: die drei verfallenen nicht-committeten Zeilen gehen, committed und frisch bleiben
    v_n := finance.fn_import_sweep();
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FAIL [verfallen] Default 7 Tage: % geloescht, erwartet 3', v_n;
    END IF;
    IF (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_batch_old) <> 0 THEN
        RAISE EXCEPTION 'FAIL [verfallen]: verfallener Batch ist noch da';
    END IF;
    RAISE NOTICE 'PASS [verfallen]: 3 verfallene nicht-committete Zeilen geloescht';

    IF (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_batch_keep AND status = 'committed') <> 1 THEN
        RAISE EXCEPTION 'FAIL [committed]: committete Zeile wurde trotz Alter geloescht';
    END IF;
    RAISE NOTICE 'PASS [committed]: committete Zeile bleibt, auch wenn sie alt ist';

    IF (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_batch_fresh) <> 2 THEN
        RAISE EXCEPTION 'FAIL [frisch]: frische Zeilen wurden geloescht';
    END IF;
    RAISE NOTICE 'PASS [frisch]: frische Zeilen bleiben';

    -- zweiter Lauf ohne Verfallenes: 0
    IF finance.fn_import_sweep() <> 0 THEN
        RAISE EXCEPTION 'FAIL [idempotent]: zweiter Lauf loescht erneut';
    END IF;

    -- Schwelle ist der Parameter: 0 Tage verwirft jede nicht-committete Zeile aelter als jetzt (die 1-Tage-Zeile)
    v_n := finance.fn_import_sweep(0);
    IF v_n < 1 OR (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_batch_keep) <> 1 THEN
        RAISE EXCEPTION 'FAIL [p_days]: sweep(0) -> % geloescht, committed muss bleiben', v_n;
    END IF;
    RAISE NOTICE 'PASS [p_days]: Schwelle folgt dem Parameter, committed bleibt immer';
END $$;
ROLLBACK;

-- ---------- Vorschlags-Stapel: Frist 7 Tage nach dem letzten Ergaenzen (merged_at), ganzer Stapel ----------
BEGIN;
DO $$
DECLARE
    v_old UUID := gen_random_uuid();
    v_new UUID := gen_random_uuid();
BEGIN
    DELETE FROM finance.import_staging;
    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, status, origin, chat_id, merged_at, created_at) VALUES
        (v_old, 1, 'recurring_payment', 'staged',    'recurring_suggestion', '1', now() - interval '8 days', now() - interval '20 days'),
        (v_old, 2, 'recurring_payment', 'declined',  'recurring_suggestion', '1', now() - interval '9 days', now() - interval '20 days'),
        (v_old, 3, 'recurring_payment', 'committed', 'recurring_suggestion', '1', now() - interval '10 days', now() - interval '20 days'),
        -- juengst ergaenzt vor 2 Tagen: der ganze Stapel bleibt, auch die alte abgelehnte Zeile
        (v_new, 1, 'recurring_payment', 'staged',    'recurring_suggestion', '2', now() - interval '2 days', now() - interval '20 days'),
        (v_new, 2, 'recurring_payment', 'declined',  'recurring_suggestion', '2', now() - interval '12 days', now() - interval '20 days');
    -- Stempeln/Ablehnen setzt updated_at (Touch-Trigger), verschiebt die Frist aber nicht
    UPDATE finance.import_staging SET sent_version = 1 WHERE batch_id = v_old;
    IF finance.fn_import_sweep() <> 3 THEN
        RAISE EXCEPTION 'FAIL [Vorschlags-Stapel 7 Tage nach merged_at]: %', (SELECT jsonb_agg(s) FROM finance.import_staging s);
    END IF;
    IF (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_new) <> 2 THEN
        RAISE EXCEPTION 'FAIL [frisch ergaenzter Stapel bleibt ganz]';
    END IF;
    RAISE NOTICE 'PASS [Vorschlags-Stapel: Frist nach max(merged_at), Stempeln verschiebt nicht]';
END $$;
ROLLBACK;
