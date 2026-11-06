-- tests/db/core/test_fn_set_cron_enable.sql
-- WS-3 (Phase A) / Phase D Rename / Phase 0 WS-0c #2/#3: core.fn_set_cron_enable schaltet das F9-Enable-Flag
-- EINES Crons in core.config (category 'cron_enable'). NEU (WS-0c): UPDATE-only + die Togglability-Sicherung
-- ist die MITGLIEDSCHAFT in core.cron_labels (ersetzt die hartkodierte Whitelist) — ein Key ist genau dann
-- chat-schaltbar, wenn er dort eine Zeile hat. always-on Crons (Default 'true', keine cron_labels-Zeile) +
-- unbekannte Keys werden abgelehnt = die Sicherung gegen beliebige Config-Writes aus dem Chat. Die fn bleibt
-- rein {ok,key,enabled} (keine Label-Rueckgabe — arch-challenge E3). Owner-Auth liegt am Orchestrator-Callback.
BEGIN;

-- Setup (self-contained, BEGIN..ROLLBACK): die cron_enable-Config-Zeilen (UPDATE-only braucht Existenz) +
-- die cron_labels-Registry. 'test_alwayson' = always-on-Probe (Default 'true', KEINE cron_labels-Zeile ->
-- nicht chat-togglable). 'wf2_probe' = frischer opt-in-Key (in der Registry, in KEINER alten Whitelist ->
-- der RED-Beweis: die alte Whitelist-fn lehnte ihn ab, die Registry-fn akzeptiert ihn).
INSERT INTO core.config (category, key, value, package) VALUES
  ('cron_enable', 'drift_check',   'true',  'core'),
  ('cron_enable', 'plan_review',   'true',  'core'),
  ('cron_enable', 'learn_context', 'true',  'core'),
  ('cron_enable', 'test_alwayson', 'true',  'finance'),
  ('cron_enable', 'wf2_probe',     'false', 'career')
ON CONFLICT (category, key) DO NOTHING;
INSERT INTO core.cron_labels (cron_key, package) VALUES
  ('drift_check',   'core'),
  ('plan_review',   'core'),
  ('learn_context', 'core'),
  ('wf2_probe',     'career')
ON CONFLICT (cron_key) DO NOTHING;

DO $$
DECLARE
  r       jsonb;
  v_val   text;
  v_pkg   text;
BEGIN
  -- TEST 1: drift_check AUS -> ok:true + core.config-Wert 'false' (drift_check ist in der Registry)
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'drift_check', 'enabled', false));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1]: off ok!=true (%)', r; END IF;
  IF (r->>'enabled')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1]: enabled!=false (%)', r; END IF;
  SELECT value INTO v_val FROM core.config WHERE category = 'cron_enable' AND key = 'drift_check';
  IF v_val IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 'FAIL [1]: core.config cron_enable.drift_check = % (erwartet false)', v_val; END IF;
  RAISE NOTICE 'PASS [drift_check AUS -> core.config false]';

  -- TEST 2: drift_check AN -> 'true' (idempotent: zweimal AN bleibt true)
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'drift_check', 'enabled', true));
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'drift_check', 'enabled', true));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2]: on ok!=true (%)', r; END IF;
  SELECT value INTO v_val FROM core.config WHERE category = 'cron_enable' AND key = 'drift_check';
  IF v_val IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'FAIL [2]: core.config cron_enable.drift_check = % (erwartet true)', v_val; END IF;
  RAISE NOTICE 'PASS [drift_check AN -> core.config true, idempotent]';

  -- TEST 3: plan_review schaltbar (zweiter Registry-Key)
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'plan_review', 'enabled', false));
  SELECT value INTO v_val FROM core.config WHERE category = 'cron_enable' AND key = 'plan_review';
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR v_val IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FAIL [3]: plan_review nicht geschaltet (r=%, val=%)', r, v_val; END IF;
  RAISE NOTICE 'PASS [plan_review schaltbar]';

  -- TEST 4: unbekannter Key (keine cron_labels-Zeile, keine Config-Zeile) -> {ok:false}, KEIN Write
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'monitor_triggers', 'enabled', false));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%cron key%' THEN
    RAISE EXCEPTION 'FAIL [4]: unbekannter Key nicht abgewiesen (%)', r; END IF;
  IF EXISTS (SELECT 1 FROM core.config WHERE category = 'cron_enable' AND key = 'monitor_triggers') THEN
    RAISE EXCEPTION 'FAIL [4]: unbekannter Key hat eine Config-Zeile geschrieben (Registry-Guard umgangen)'; END IF;
  RAISE NOTICE 'PASS [unbekannter Key -> ok:false, kein Write]';

  -- TEST 5: nicht-boolescher enabled -> {ok:false}
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'drift_check', 'enabled', 'vielleicht'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5]: nicht-bool enabled akzeptiert (%)', r; END IF;
  RAISE NOTICE 'PASS [nicht-boolescher enabled -> ok:false]';

  -- TEST 6: learn_context schaltbar (dritter Registry-Key, Anschalt-Wiederverwendung Phase C)
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'learn_context', 'enabled', true));
  SELECT value INTO v_val FROM core.config WHERE category = 'cron_enable' AND key = 'learn_context';
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR v_val IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [6]: learn_context nicht geschaltet (r=%, val=%)', r, v_val; END IF;
  RAISE NOTICE 'PASS [learn_context schaltbar]';

  -- TEST 7: always-on-Key (Config-Zeile existiert mit value 'true', aber KEINE cron_labels-Zeile)
  --   -> {ok:false} + KEIN Write (die Registry-Membership ist die Togglability-Sicherung; das ist die
  --   strukturelle Garantie "always-on Crons sind nicht aus dem Chat schaltbar")
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'test_alwayson', 'enabled', false));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [7]: always-on-Key (nicht in Registry) wurde akzeptiert (%)', r; END IF;
  SELECT value INTO v_val FROM core.config WHERE category = 'cron_enable' AND key = 'test_alwayson';
  IF v_val IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'FAIL [7]: always-on-Key wurde geschaltet (value=% statt true) -- Chat-Toggle eines always-on-Crons!', v_val; END IF;
  RAISE NOTICE 'PASS [always-on-Key nicht in Registry -> ok:false, kein Write]';

  -- TEST 8: frischer opt-in-Key 'wf2_probe' (in der Registry, in KEINER alten Whitelist) -> ok:true
  --   = der generische Beweis: ein neues Paket macht seinen opt-in-Cron schaltbar, indem es NUR eine
  --   cron_labels-Zeile deklariert -- ohne Edit an der fn (die alte Whitelist-fn haette ihn abgelehnt).
  r := core.fn_set_cron_enable(jsonb_build_object('key', 'wf2_probe', 'enabled', true));
  SELECT value INTO v_val FROM core.config WHERE category = 'cron_enable' AND key = 'wf2_probe';
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR v_val IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [8]: frischer Registry-Key wf2_probe nicht geschaltet (r=%, val=%) -- generischer Pfad gebrochen', r, v_val; END IF;
  RAISE NOTICE 'PASS [frischer Registry-Key wf2_probe schaltbar -> generisch, kein fn-Edit]';

  -- TEST 9: package der Config-Zeile bleibt unveraendert (UPDATE-only beruehrt package NICHT; nie 'core' hartkodieren)
  SELECT package INTO v_pkg FROM core.config WHERE category = 'cron_enable' AND key = 'wf2_probe';
  IF v_pkg IS DISTINCT FROM 'career' THEN RAISE EXCEPTION 'FAIL [9]: package der wf2_probe-Zeile = % (erwartet career, unveraendert) -- die fn hat package ueberschrieben', v_pkg; END IF;
  RAISE NOTICE 'PASS [package der Config-Zeile unveraendert (career)]';
END $$;

ROLLBACK;
