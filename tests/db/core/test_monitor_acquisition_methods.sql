-- tests/db/core/test_monitor_acquisition_methods.sql
-- Phase B: core.monitor_acquisition_methods (Registry der Monitor-Beschaffungs-Methoden) + ihre DB-Gesetze.
--   (1) FK agent.monitor_triggers.acquisition_method -> Registry existiert + ist validiert; unbekannte Methode
--       per Direkt-INSERT -> foreign_key_violation; Builtins vorhanden; Registry-CHECKs
--   (2) Spec-Validierungs-Trigger: ungueltige Spec einer verfuegbaren Paket-Methode -> check_violation;
--       Heartbeat-UPDATE (last_value/fail_streak) feuert ihn NICHT; Spec-UPDATE schon; nicht verfuegbare
--       Methode -> uebersprungen (FK haelt die Mitgliedschaft)
--   (3) fn_monitor_method_status: builtin / unknown / Platzhalter / inaktiv / verfuegbar
--   (4) Purge Schritt 3c: Trigger der Paket-Methode (auch package='core') + Methoden-Zeile weg, gezaehlt
--   (5) Restore: Bundle-Trigger mit unregistrierter Methode -> verstaendlicher Abbruch (kein FK-Kauderwelsch)
-- Stub-Paket zz_pkg (in der TX angelegt). BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

CREATE SCHEMA zz_pkg;
CREATE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE WHEN (p->'params'->>'v') ~ '^[0-9.]+$'
              THEN jsonb_build_object('ok', true, 'spec', jsonb_build_object('v', (p->'params'->>'v')::numeric), 'display', 'd')
              ELSE jsonb_build_object('ok', false, 'reason', 'v must be numeric') END $f$;
CREATE FUNCTION zz_pkg.fn_acquire(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('ok', true, 'value', (p->'spec'->>'v')::numeric) $f$;
INSERT INTO core.package_registry (package, status) VALUES ('zz_pkg', 'active');
INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package)
VALUES ('zz_test', 'zz_pkg.fn_acquire', 'zz_pkg.fn_validate', 'zz_pkg');

DO $$
DECLARE
  v_id  int;
  v_ok  boolean;
  r     jsonb;
BEGIN
  -- ===== (1) FK + Builtins + Registry-CHECKs =====
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'agent.monitor_triggers'::regclass
                    AND conname = 'monitor_triggers_acquisition_method_fk' AND contype = 'f' AND convalidated) THEN
    RAISE EXCEPTION 'FAIL (1) FK monitor_triggers_acquisition_method_fk fehlt oder ist nicht validiert';
  END IF;
  IF (SELECT count(*) FROM core.monitor_acquisition_methods WHERE method IN ('web_search','sql','none') AND package = 'core') <> 3 THEN
    RAISE EXCEPTION 'FAIL (1) Core-Builtins fehlen';
  END IF;
  v_ok := false;
  BEGIN
    INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec,
                                        comparator, threshold_value, check_interval)
    VALUES ('__test__', 'fk probe', 'threshold', 'zz_nope', '{}', 'gte', 1, INTERVAL '1 day');
  EXCEPTION WHEN foreign_key_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL (1) unregistrierte Methode per Direkt-INSERT akzeptiert'; END IF;
  v_ok := false;
  BEGIN
    INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, package) VALUES ('zz_half', 'zz_pkg.fn_acquire', 'zz_pkg');
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL (1) halb registrierte Methode (nur acquire_fn) akzeptiert'; END IF;
  RAISE NOTICE 'PASS (1) FK validiert, Builtins da, unbekannte/halbe Methode abgelehnt';

  -- ===== (2) Spec-Validierungs-Trigger =====
  v_ok := false;
  BEGIN
    INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec,
                                        comparator, threshold_value, check_interval)
    VALUES ('__test__', 'bad spec', 'threshold', 'zz_test', '{"v": "abc"}', 'gte', 1, INTERVAL '1 day');
  EXCEPTION WHEN check_violation THEN v_ok := SQLERRM ILIKE '%invalid acquisition_spec for zz_test%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL (2) ungueltige Paket-Spec nicht als check_violation abgelehnt'; END IF;

  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec,
                                      comparator, threshold_value, check_interval)
  VALUES ('__test__', 'good spec', 'threshold', 'zz_test', '{"v": 5}', 'gte', 1, INTERVAL '1 day')
  RETURNING id INTO v_id;

  -- validate_fn wird ab jetzt alles ablehnen: ein Heartbeat-UPDATE darf den Trigger NICHT feuern ...
  CREATE OR REPLACE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ok', false, 'reason', 'rejects everything') $f$;
  UPDATE agent.monitor_triggers SET last_value = 6, fail_streak = 0, next_check_at = now() WHERE id = v_id;
  -- ... ein Spec-UPDATE schon
  v_ok := false;
  BEGIN
    UPDATE agent.monitor_triggers SET acquisition_spec = '{"v": 7}' WHERE id = v_id;
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL (2) Spec-UPDATE nicht validiert'; END IF;

  -- nicht verfuegbare Methode (Paket inaktiv) -> Backstop uebersprungen (Disable/Repair bleiben moeglich)
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'zz_pkg';
  UPDATE agent.monitor_triggers SET acquisition_spec = '{"v": 8}' WHERE id = v_id;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'zz_pkg';
  RAISE NOTICE 'PASS (2) Spec-Trigger: lehnt ab, Heartbeat-UPDATE unberuehrt, Spec-UPDATE geprueft, inaktiv uebersprungen';

  -- ===== (3) fn_monitor_method_status =====
  IF (agent.fn_monitor_method_status('sql')->>'builtin')::boolean IS DISTINCT FROM true
     OR (agent.fn_monitor_method_status('zz_nope')->>'available')::boolean IS DISTINCT FROM false
     OR (agent.fn_monitor_method_status('zz_test')->>'available')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL (3) method_status builtin/unknown/available';
  END IF;
  INSERT INTO core.monitor_acquisition_methods (method) VALUES ('zz_placeholder');
  r := agent.fn_monitor_method_status('zz_placeholder');
  IF (r->>'available')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%not installed%' THEN
    RAISE EXCEPTION 'FAIL (3) Platzhalter nicht als nicht installiert erkannt: %', r;
  END IF;
  RAISE NOTICE 'PASS (3) fn_monitor_method_status';

  -- ===== (4) Purge Schritt 3c =====
  CREATE OR REPLACE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ok', true, 'spec', p->'params') $f$;
  INSERT INTO agent.monitor_triggers (domain, package, label, trigger_type, acquisition_method, acquisition_spec,
                                      comparator, threshold_value, check_interval)
  VALUES ('general', 'core', 'core-made zz trigger', 'threshold', 'zz_test', '{"v": 9}', 'gte', 1, INTERVAL '1 day');
  r := core.fn_pkg_purge_data(jsonb_build_object('package', 'zz_pkg'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'method_triggers')::int <> 2 OR (r->>'acquisition_methods')::int <> 1
     OR EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE acquisition_method = 'zz_test')
     OR EXISTS (SELECT 1 FROM core.monitor_acquisition_methods WHERE method = 'zz_test') THEN
    RAISE EXCEPTION 'FAIL (4) Purge 3c: %', r;
  END IF;
  RAISE NOTICE 'PASS (4) Purge 3c: Methoden-Trigger (auch package=core) + Methode gezaehlt entfernt';

  -- ===== (5) Restore mit unregistrierter Methode -> verstaendlicher Abbruch =====
  v_ok := false;
  BEGIN
    PERFORM core.fn_backup_restore_filtered(jsonb_build_object('agent.monitor_triggers', jsonb_build_array(
      jsonb_build_object('domain', 'general', 'label', 'from bundle', 'trigger_type', 'threshold',
                         'acquisition_method', 'zz_gone', 'acquisition_spec', '{}'::jsonb, 'comparator', 'gte',
                         'threshold_value', 1, 'check_interval', '1 day', 'origin', 'user', 'package', 'core'))));
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM ILIKE '%zz_gone%install%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL (5) Restore mit unregistrierter Methode nicht verstaendlich abgebrochen'; END IF;
  RAISE NOTICE 'PASS (5) Restore: unregistrierte Methode -> klarer Abbruch';
END $$;

ROLLBACK;
