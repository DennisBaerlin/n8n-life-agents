-- tests/db/core/test_fn_heartbeat_record.sql
-- Lebenszeichen des Hintergrund-Teils (core.heartbeats + core.heartbeat_observer, core.fn_heartbeat_record).
--   1) erster Beat legt alle drei Signal-Zeilen an (die nicht gemeldeten als 'pending') und die Beobachter-Zeile
--   2) Statuswechsel stempelt status_since, gleicher Status nicht; jeder Beat setzt stale_observed_s auf 0
--   3) busy: busy_until = now + busy_s; ohne busy_s, mit busy_s <= 0 oder > 4 h -> Fehler; Folge-Beat ok raeumt busy
--   4) backup: notified_at aus Epoch, fehlt es -> bleibt der alte Wert; notified_at an loop -> Fehler
--   5) ungueltig: unbekanntes Signal, Status nicht zum Signal, runtime fehlt/unbekannt, help_url ohne https -> Fehler
--   6) help_url: ein Beat ohne help_url behaelt den gespeicherten Link
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;

DELETE FROM core.heartbeats;
DELETE FROM core.heartbeat_observer;

DO $$
DECLARE
  r      jsonb;
  v_n    int;
  v_row  core.heartbeats%ROWTYPE;
  v_obs  core.heartbeat_observer%ROWTYPE;
  v_ok   boolean;
BEGIN
  -- ===== 1) erster Beat =====
  r := core.fn_heartbeat_record('{"signal":"loop","status":"ok","runtime":"compose","help_url":"https://example.org/docs/hilfe.html"}');
  IF r->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'FAIL [1a] ok:true erwartet: %', r; END IF;
  SELECT count(*) INTO v_n FROM core.heartbeats;
  IF v_n <> 3 THEN RAISE EXCEPTION 'FAIL [1b] drei Zeilen erwartet, % gefunden', v_n; END IF;
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'check';
  IF v_row.status <> 'pending' OR v_row.beat_at <> now() THEN RAISE EXCEPTION 'FAIL [1c] check pending ab jetzt: %', row_to_json(v_row); END IF;
  SELECT * INTO v_obs FROM core.heartbeat_observer;
  IF v_obs.runtime <> 'compose' OR v_obs.help_url <> 'https://example.org/docs/hilfe.html' OR v_obs.seen_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1d] Beobachter: %', row_to_json(v_obs); END IF;
  RAISE NOTICE 'PASS [1] erster Beat legt drei Signale + Beobachter an';

  -- ===== 2) status_since / stale =====
  UPDATE core.heartbeats SET beat_at = now() - interval '2 hours', status_since = now() - interval '2 hours',
                             stale_observed_s = 1234 WHERE signal = 'loop';
  PERFORM core.fn_heartbeat_record('{"signal":"loop","status":"ok","runtime":"compose"}');
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'loop';
  IF v_row.status_since <> now() - interval '2 hours' THEN RAISE EXCEPTION 'FAIL [2a] gleicher Status darf status_since nicht stempeln'; END IF;
  IF v_row.stale_observed_s <> 0 OR v_row.beat_at <> now() THEN RAISE EXCEPTION 'FAIL [2b] Beat setzt stale 0 und beat_at now: %', row_to_json(v_row); END IF;
  PERFORM core.fn_heartbeat_record('{"signal":"check","status":"not_release","runtime":"compose"}');
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'check';
  IF v_row.status <> 'not_release' OR v_row.status_since <> now() THEN RAISE EXCEPTION 'FAIL [2c] Statuswechsel stempelt status_since'; END IF;
  RAISE NOTICE 'PASS [2] status_since nur bei Wechsel, Beat setzt stale zurueck';

  -- ===== 3) busy =====
  PERFORM core.fn_heartbeat_record('{"signal":"loop","status":"busy","busy_s":7260,"runtime":"systemd"}');
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'loop';
  IF v_row.busy_until <> now() + interval '7260 seconds' THEN RAISE EXCEPTION 'FAIL [3a] busy_until: %', v_row.busy_until; END IF;
  SELECT runtime INTO v_obs.runtime FROM core.heartbeat_observer;
  IF v_obs.runtime <> 'systemd' THEN RAISE EXCEPTION 'FAIL [3b] runtime folgt dem letzten Beat'; END IF;
  FOREACH r IN ARRAY ARRAY['{"signal":"loop","status":"busy","runtime":"systemd"}',
                           '{"signal":"loop","status":"busy","busy_s":0,"runtime":"systemd"}',
                           '{"signal":"loop","status":"busy","busy_s":14401,"runtime":"systemd"}']::jsonb[] LOOP
    v_ok := false;
    BEGIN PERFORM core.fn_heartbeat_record(r); EXCEPTION WHEN OTHERS THEN v_ok := true; END;
    IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [3c] ungueltiges busy angenommen: %', r; END IF;
  END LOOP;
  PERFORM core.fn_heartbeat_record('{"signal":"loop","status":"ok","runtime":"systemd"}');
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'loop';
  IF v_row.busy_until IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3d] ok-Beat raeumt busy_until'; END IF;
  RAISE NOTICE 'PASS [3] busy mit Grenze, ok raeumt';

  -- ===== 4) backup notified_at =====
  PERFORM core.fn_heartbeat_record('{"signal":"backup","status":"attempted","notified_at":1781000000,"runtime":"systemd"}');
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'backup';
  IF v_row.notified_at <> to_timestamp(1781000000) THEN RAISE EXCEPTION 'FAIL [4a] notified_at aus Epoch: %', v_row.notified_at; END IF;
  PERFORM core.fn_heartbeat_record('{"signal":"backup","status":"current","runtime":"systemd"}');
  SELECT * INTO v_row FROM core.heartbeats WHERE signal = 'backup';
  IF v_row.notified_at <> to_timestamp(1781000000) THEN RAISE EXCEPTION 'FAIL [4b] fehlendes notified_at behaelt den alten Wert'; END IF;
  v_ok := false;
  BEGIN PERFORM core.fn_heartbeat_record('{"signal":"loop","status":"ok","notified_at":1781000000,"runtime":"systemd"}');
  EXCEPTION WHEN OTHERS THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [4c] notified_at an loop angenommen'; END IF;
  RAISE NOTICE 'PASS [4] backup notified_at';

  -- ===== 5) ungueltig =====
  FOREACH r IN ARRAY ARRAY['{"signal":"tick","status":"ok","runtime":"systemd"}',
                           '{"signal":"check","status":"current","runtime":"systemd"}',
                           '{"signal":"backup","status":"ok","runtime":"systemd"}',
                           '{"signal":"loop","status":"ok"}',
                           '{"signal":"loop","status":"ok","runtime":"podman"}',
                           '{"signal":"loop","status":"ok","runtime":"systemd","help_url":"http://example.org/x"}',
                           '{"status":"ok","runtime":"systemd"}']::jsonb[] LOOP
    v_ok := false;
    BEGIN PERFORM core.fn_heartbeat_record(r); EXCEPTION WHEN OTHERS THEN v_ok := true; END;
    IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [5] ungueltiger Beat angenommen: %', r; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [5] ungueltige Beats werfen';

  -- ===== 6) help_url bleibt =====
  SELECT help_url INTO v_obs.help_url FROM core.heartbeat_observer;
  IF v_obs.help_url <> 'https://example.org/docs/hilfe.html' THEN RAISE EXCEPTION 'FAIL [6] help_url verloren: %', v_obs.help_url; END IF;
  RAISE NOTICE 'PASS [6] Beat ohne help_url behaelt den Link';
END $$;

ROLLBACK;
