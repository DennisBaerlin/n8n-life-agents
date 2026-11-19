-- ============================================================
-- fn_heartbeat_record (WRITE) — Lebenszeichen des Hintergrund-Teils
--   Ein Lauf des root-Teils meldet sich (Tabellen: packages/core/db/core.heartbeats_init.sql). Aufrufer nur root
--   ueber pg_su_psql (provisioning/lib/common.sh heartbeat_record): update --run-requested, Release-Check, backup auto,
--   Einrichtung. Der erste Beat legt alle drei Signal-Zeilen an (die anderen als 'pending' ab jetzt) -> „lief nach der
--   Einrichtung nie" wird meldbar. Jeder Beat setzt die beobachtete Zeit seines Signals auf 0.
--   p: {signal: loop|check|backup, status (je Signal: core.heartbeats CHECK), runtime: compose|systemd (Pflicht),
--       busy_s (Pflicht bei status busy: Sekunden bis busy_until, 1..14400), notified_at (nur backup: Epoch der letzten
--       eigenen Sicherungs-Meldung; fehlt -> alter Wert), help_url (optional, https; fehlt -> gespeicherter Link),
--       at (nur Test: Zeitpunkt statt now())}
--   Rueckgabe: {ok:true}. Ungueltiges wirft (CHECK/RAISE): ein falscher Beat ist ein Code-Fehler im root-Teil, kein
--   Nutzerfehler; der Aufrufer loggt nur und laeuft weiter.
--   INVOKER (Aufrufer = Superuser; db_test als Superuser).
--   Tests: tests/db/core/test_fn_heartbeat_record.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_heartbeat_record(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_now    timestamptz := CASE WHEN pg_input_is_valid(p->>'at', 'timestamptz') THEN (p->>'at')::timestamptz ELSE now() END;
    v_sig    text := p->>'signal';
    v_status text := p->>'status';
    v_busy   timestamptz;
BEGIN
    IF v_sig IS NULL OR v_status IS NULL OR p->>'runtime' IS NULL THEN
        RAISE EXCEPTION 'fn_heartbeat_record: signal, status and runtime are required (%)', p;
    END IF;
    IF v_status = 'busy' THEN
        IF NOT pg_input_is_valid(p->>'busy_s', 'int') OR (p->>'busy_s')::int <= 0 THEN
            RAISE EXCEPTION 'fn_heartbeat_record: status busy needs busy_s > 0 (%)', p;
        END IF;
        v_busy := v_now + make_interval(secs => (p->>'busy_s')::int);
    END IF;

    INSERT INTO core.heartbeat_observer (id, runtime, help_url) VALUES (TRUE, p->>'runtime', NULLIF(p->>'help_url', ''))
    ON CONFLICT (id) DO UPDATE SET runtime  = EXCLUDED.runtime,
                                   help_url = COALESCE(EXCLUDED.help_url, core.heartbeat_observer.help_url);

    INSERT INTO core.heartbeats (signal, status, beat_at, status_since)
    SELECT s, 'pending', v_now, v_now FROM unnest(ARRAY['loop', 'check', 'backup']) s
    ON CONFLICT (signal) DO NOTHING;

    UPDATE core.heartbeats h
       SET status           = v_status,
           status_since     = CASE WHEN h.status IS DISTINCT FROM v_status THEN v_now ELSE h.status_since END,
           beat_at          = v_now,
           busy_until       = v_busy,
           notified_at      = CASE WHEN COALESCE(p->>'notified_at', '') = '' THEN h.notified_at
                                   ELSE to_timestamp((p->>'notified_at')::bigint) END,
           stale_observed_s = 0
     WHERE h.signal = v_sig;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_heartbeat_record: unknown signal %', v_sig;
    END IF;
    RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_heartbeat_record(jsonb) FROM public;
