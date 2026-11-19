-- ============================================================
-- fn_heartbeat_finish (WRITE) — Ergebnis des Sendens eines Waechter-Textes
--   Gegenstueck zu core.fn_heartbeat_claim; Aufrufer core.cron_heartbeat_watch je Nachricht nach dem Telegram-Versuch.
--   p: {key (Pflicht, Schluessel aus dem Claim), sent (Pflicht, boolean), at (nur Test: Zeitpunkt statt now())}
--   sent=true:  Merker festgeschrieben (core.fn_notify_commit), Sende-Abstand zurueck. Stufe '<signal>:<epoch>:<n>' ->
--               alert_stage = n, last_alert_at; '<signal>:<epoch>:clear' -> Vorfall geschlossen, last_clear_at;
--               'lookback:<epoch>' -> offene Luecke geschlossen. Immer nur, wenn Vorfall bzw. Luecke noch dieselbe ist,
--               die Stufe nur aufwaerts.
--   sent=false: Merker wieder frei (core.fn_notify_resolve); fail_count + 1, retry_after = now + 30 min · 2^(fail_count−1),
--               hoechstens 24 h (blockierter Bot, Netz weg: nicht jede 10 Minuten vergeblich).
--   Rueckgabe: {ok:true}. Kaputter Schluessel oder sent kein boolean wirft (Code-Fehler im Workflow).
--   INVOKER wie core.fn_heartbeat_claim.
--   Tests: tests/db/core/test_fn_heartbeat_finish.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_heartbeat_finish(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_now  timestamptz := CASE WHEN pg_input_is_valid(p->>'at', 'timestamptz') THEN (p->>'at')::timestamptz ELSE now() END;
    v_key  text := p->>'key';
    v_m    text[];
BEGIN
    v_m := regexp_match(COALESCE(v_key, ''), '^(?:(loop|check|backup):([0-9]+):([1-9][0-9]*|clear)|lookback:([0-9]+))$');
    IF v_m IS NULL OR jsonb_typeof(p->'sent') IS DISTINCT FROM 'boolean' THEN
        RAISE EXCEPTION 'fn_heartbeat_finish: key and sent (boolean) are required (%)', p;
    END IF;

    IF NOT (p->>'sent')::boolean THEN
        PERFORM core.fn_notify_resolve('heartbeat', v_key);
        UPDATE core.heartbeat_observer
           SET fail_count  = fail_count + 1,
               retry_after = v_now + least(interval '30 minutes' * (2 ^ least(fail_count, 10)), interval '24 hours')
         WHERE id;
        RETURN jsonb_build_object('ok', true);
    END IF;

    PERFORM core.fn_notify_commit('heartbeat', v_key);
    UPDATE core.heartbeat_observer SET fail_count = 0, retry_after = NULL WHERE id;
    IF v_m[4] IS NOT NULL THEN
        UPDATE core.heartbeat_observer SET lookback_from = NULL, lookback_gap_s = NULL
         WHERE id AND floor(extract(epoch FROM lookback_from))::bigint = v_m[4]::bigint;
    ELSIF v_m[3] = 'clear' THEN
        UPDATE core.heartbeats
           SET alert_stage = 0, last_alert_at = NULL, incident_at = NULL, last_clear_at = v_now
         WHERE signal = v_m[1] AND floor(extract(epoch FROM incident_at))::bigint = v_m[2]::bigint;
    ELSE
        UPDATE core.heartbeats
           SET alert_stage = v_m[3]::int, last_alert_at = v_now
         WHERE signal = v_m[1] AND floor(extract(epoch FROM incident_at))::bigint = v_m[2]::bigint
           AND alert_stage < v_m[3]::int;
    END IF;
    RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_heartbeat_finish(jsonb) FROM public;
