-- tests/db/core/test_fn_heartbeat_finish.sql
-- Ergebnis des Sendens eines Waechter-Textes (core.fn_heartbeat_finish). Der Ablauf mit claim steht in
-- test_fn_heartbeat_claim.sql; hier nur der Vertrag der fn selbst.
--   1) sent=true: Merker festgeschrieben (state fired, ohne Frist), Stufe vermerkt, nur fuer den eigenen Vorfall
--   2) sent=false: Merker wieder frei, Abstand 30 min * 2^(Fehlschlaege-1), hoechstens 24 h; mehrere gescheiterte Texte
--      eines Laufs zaehlen als ein Fehlschlag
--   3) Entwarnung schliesst den Vorfall; Rueckblick schliesst nur die eigene Luecke
--   4) kaputter Schluessel oder sent kein boolean -> Fehler (Code-Fehler, kein ok:false)
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;

DELETE FROM core.heartbeats;
DELETE FROM core.heartbeat_observer;
DELETE FROM core.notification_state WHERE source = 'heartbeat';

DO $$
DECLARE
  v_inc  timestamptz := now() - interval '1 hour';
  v_ep   bigint := floor(extract(epoch FROM now() - interval '1 hour'))::bigint;
  v_key  text;
  v_at   timestamptz;
  v_ok   boolean;
  v_row  core.heartbeats%ROWTYPE;
  v_obs  core.heartbeat_observer%ROWTYPE;
  r      jsonb;
BEGIN
  PERFORM core.fn_heartbeat_record('{"signal":"loop","status":"ok","runtime":"systemd","help_url":"https://example.org/h"}');
  UPDATE core.heartbeats SET incident_at = v_inc WHERE signal = 'loop';

  -- ===== 1) sent=true =====
  v_key := 'loop:' || v_ep || ':1';
  PERFORM core.fn_should_notify('heartbeat', v_key, interval '30 minutes');
  r := core.fn_heartbeat_finish(jsonb_build_object('key', v_key, 'sent', true));
  IF r->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'FAIL [1a] ok:true: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'heartbeat' AND key = v_key
                  AND state = 'fired' AND expires_at IS NULL) THEN RAISE EXCEPTION 'FAIL [1b] Merker festgeschrieben'; END IF;
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'loop';
  IF v_row.alert_stage <> 1 OR v_row.last_alert_at <> now() THEN RAISE EXCEPTION 'FAIL [1c] Stufe 1 vermerkt: %', row_to_json(v_row); END IF;
  PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', 'loop:' || (v_ep - 5) || ':2', 'sent', true));
  IF (SELECT alert_stage FROM core.heartbeats WHERE signal = 'loop') <> 1 THEN RAISE EXCEPTION 'FAIL [1d] fremder Vorfall aendert nichts'; END IF;
  RAISE NOTICE 'PASS [1] sent=true';

  -- ===== 2) sent=false =====
  v_key := 'loop:' || v_ep || ':2';
  v_at  := now();
  FOR i IN 1..7 LOOP
    -- je Lauf (at = Ablauf des vorigen Abstands) zwei gescheiterte Texte: der zweite zaehlt nicht noch einmal
    PERFORM core.fn_should_notify('heartbeat', v_key, interval '30 minutes');
    PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', v_key, 'sent', false, 'at', v_at));
    PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', 'lookback:' || v_ep, 'sent', false, 'at', v_at));
    SELECT * INTO v_obs FROM core.heartbeat_observer;
    IF v_obs.fail_count <> i OR v_obs.retry_after <> v_at + least(interval '30 minutes' * (2 ^ (i - 1)), interval '24 hours') THEN
      RAISE EXCEPTION 'FAIL [2a] Abstand nach % Laeufen: % / %', i, v_obs.fail_count, v_obs.retry_after; END IF;
    v_at := v_obs.retry_after;
  END LOOP;
  IF (SELECT state FROM core.notification_state WHERE source = 'heartbeat' AND key = v_key) <> 'ok' THEN
    RAISE EXCEPTION 'FAIL [2b] Merker nach Fehlschlag frei'; END IF;
  IF (SELECT alert_stage FROM core.heartbeats WHERE signal = 'loop') <> 1 THEN RAISE EXCEPTION 'FAIL [2c] Fehlschlag vermerkt keine Stufe'; END IF;
  RAISE NOTICE 'PASS [2] sent=false: Abstand waechst bis 24 h';

  -- ===== 3) Entwarnung, Rueckblick =====
  PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', 'loop:' || v_ep || ':clear', 'sent', true));
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'loop';
  IF v_row.alert_stage <> 0 OR v_row.last_alert_at IS NOT NULL OR v_row.incident_at IS NOT NULL OR v_row.last_clear_at <> now() THEN
    RAISE EXCEPTION 'FAIL [3a] Entwarnung schliesst den Vorfall: %', row_to_json(v_row); END IF;
  SELECT * INTO v_obs FROM core.heartbeat_observer;
  IF v_obs.fail_count <> 0 OR v_obs.retry_after IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3b] Erfolg setzt den Abstand zurueck'; END IF;
  UPDATE core.heartbeat_observer SET lookback_from = v_inc, lookback_gap_s = 90000;
  PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', 'lookback:' || (v_ep + 1), 'sent', true));
  IF (SELECT lookback_from FROM core.heartbeat_observer) IS NULL THEN RAISE EXCEPTION 'FAIL [3c] fremde Luecke bleibt offen'; END IF;
  PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', 'lookback:' || v_ep, 'sent', true));
  SELECT * INTO v_obs FROM core.heartbeat_observer;
  IF v_obs.lookback_from IS NOT NULL OR v_obs.lookback_gap_s IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3d] eigene Luecke geschlossen'; END IF;
  RAISE NOTICE 'PASS [3] Entwarnung, Rueckblick';

  -- ===== 4) kaputte Eingaben =====
  FOREACH r IN ARRAY ARRAY['{"key":"loop:1","sent":true}', '{"key":"tick:1:1","sent":true}', '{"key":"loop:x:1","sent":true}',
                           '{"key":"loop:1:0","sent":true}', '{"key":"loop:1:1"}', '{"key":"loop:1:1","sent":"ja"}',
                           '{"sent":true}']::jsonb[] LOOP
    v_ok := false;
    BEGIN PERFORM core.fn_heartbeat_finish(r); EXCEPTION WHEN OTHERS THEN v_ok := true; END;
    IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [4] kaputte Eingabe angenommen: %', r; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [4] kaputte Eingaben werfen';
END $$;

ROLLBACK;
