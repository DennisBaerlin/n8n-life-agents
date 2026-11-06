-- tests/db/core/test_fn_dry_run.sql
-- core.fn_dry_run(regprocedure, jsonb): Probelauf einer Write-fn VOR der HITL-Karte. Die fn laeuft echt, das Ergebnis
--   kommt zurueck (+ dry_run:true), ihre Effekte werden IMMER zurueckgerollt (auch bei ok:false nach einem Teil-Write).
--   Eine echte Exception der fn wird durchgereicht (nicht verschluckt). Nur fn(jsonb) RETURNS jsonb ist erlaubt.
--   core.fn_today(): heute in der Sitzungs-Zeitzone (= Haushalts-Zeitzone, eine Adresse fuer "heute").
-- Self-contained (pg_temp-fns + Temp-Tabelle), laeuft ohne jedes Paket.
BEGIN;

CREATE TEMP TABLE dry_probe (v text);

CREATE FUNCTION pg_temp.fn_probe_ok(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
    INSERT INTO dry_probe VALUES (p->>'v');
    RETURN jsonb_build_object('ok', true, 'written', p->>'v', 'effective_date', DATE '2026-10-23');
END $f$;

CREATE FUNCTION pg_temp.fn_probe_partial_fail(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
    INSERT INTO dry_probe VALUES ('partial');
    RETURN jsonb_build_object('ok', false, 'reason', 'second step rejected', 'candidates', jsonb_build_array('A', 'B'));
END $f$;

CREATE FUNCTION pg_temp.fn_probe_raise(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
    INSERT INTO dry_probe VALUES ('raised');
    RAISE EXCEPTION 'boom %', p->>'v';
END $f$;

CREATE FUNCTION pg_temp.fn_probe_wrong_sig(p text) RETURNS jsonb LANGUAGE sql AS $f$ SELECT '{}'::jsonb $f$;

DO $$
DECLARE
    v_r jsonb;
    v_n int;
BEGIN
    -- (1) ok:true -> Ergebnis zurueck, Effekt zurueckgerollt
    v_r := core.fn_dry_run('pg_temp.fn_probe_ok(jsonb)'::regprocedure, '{"v":"x"}'::jsonb);
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'written' IS DISTINCT FROM 'x'
       OR (v_r->>'dry_run')::boolean IS DISTINCT FROM true OR v_r->>'effective_date' IS DISTINCT FROM '2026-10-23' THEN
        RAISE EXCEPTION 'FAIL dry_run [ok-Ergebnis: %]', v_r; END IF;
    SELECT count(*) INTO v_n FROM dry_probe;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL dry_run [ok:true nicht zurueckgerollt: % Zeile(n)]', v_n; END IF;

    -- (2) ok:false nach Teil-Write -> reason + candidates zurueck, Teil-Write zurueckgerollt
    v_r := core.fn_dry_run('pg_temp.fn_probe_partial_fail(jsonb)'::regprocedure, '{}'::jsonb);
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' IS DISTINCT FROM 'second step rejected'
       OR jsonb_array_length(v_r->'candidates') <> 2 THEN
        RAISE EXCEPTION 'FAIL dry_run [ok:false-Ergebnis: %]', v_r; END IF;
    SELECT count(*) INTO v_n FROM dry_probe;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL dry_run [Teil-Write vor ok:false nicht zurueckgerollt]'; END IF;

    -- (3) echte Exception der fn wird NICHT verschluckt (Owner-Alert ueber errorWorkflow), nichts geschrieben
    BEGIN
        v_r := core.fn_dry_run('pg_temp.fn_probe_raise(jsonb)'::regprocedure, '{"v":"7"}'::jsonb);
        RAISE EXCEPTION 'FAIL dry_run [Exception verschluckt: %]', v_r;
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%boom 7%' THEN RAISE; END IF;
    END;
    SELECT count(*) INTO v_n FROM dry_probe;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL dry_run [Write vor Exception nicht zurueckgerollt]'; END IF;

    -- (4) falsche Signatur -> RAISE (Programmierfehler im Build, kein Nutzerfehler)
    BEGIN
        PERFORM core.fn_dry_run('pg_temp.fn_probe_wrong_sig(text)'::regprocedure, '{}'::jsonb);
        RAISE EXCEPTION 'FAIL dry_run [falsche Signatur akzeptiert]';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    END;

    -- (5) fn_today = Kalendertag der Sitzungs-Zeitzone (die der Installer je DB auf die Haushalts-Zeitzone setzt):
    --     23:30 UTC am 23.10. ist in UTC noch der 23., in Berlin (MESZ, +2) schon der 24.; ohne Argument = CURRENT_DATE.
    PERFORM pg_catalog.set_config('TimeZone', 'UTC', true);
    IF core.fn_today('2026-10-23 23:30:00+00') IS DISTINCT FROM DATE '2026-10-23' THEN
        RAISE EXCEPTION 'FAIL fn_today [UTC: %]', core.fn_today('2026-10-23 23:30:00+00'); END IF;
    PERFORM pg_catalog.set_config('TimeZone', 'Europe/Berlin', true);
    IF core.fn_today('2026-10-23 23:30:00+00') IS DISTINCT FROM DATE '2026-10-24' THEN
        RAISE EXCEPTION 'FAIL fn_today [Berlin: %]', core.fn_today('2026-10-23 23:30:00+00'); END IF;
    IF core.fn_today() IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'FAIL fn_today [% statt CURRENT_DATE %]', core.fn_today(), CURRENT_DATE; END IF;

    RAISE NOTICE 'PASS fn_dry_run [ok/ok:false zurueckgerollt, Exception durchgereicht, Signatur-Guard] + fn_today [Sitzungs-Zeitzone]';
END $$;

ROLLBACK;
