-- tests/db/core/test_fn_package_status.sql
-- Install-UX-Phase 4 (Schritt 2): core.fn_package_status — die Laufzeit-Weiche des Core-Vermittlers
--   agent.sub_dispatch_agent ("ist das Ziel-Paket nutzbar?"). Status-Matrix: keine Registry-Zeile -> not_installed;
--   installing/installed -> incomplete; inactive -> inactive; active -> ok. is_owner = der Absender ist der Owner
--   (fn_resolve_sender role='owner'); nicht-numerische/fehlende chat_id -> false (nie Exception).
--   Muster: BEGIN…ROLLBACK, eigene Zeilen; RAISE EXCEPTION 'FAIL …' = Test rot.
BEGIN;

DO $$
DECLARE r jsonb; v_pkg text := '__test_pkg_status__';
BEGIN
  DELETE FROM core.package_registry WHERE package = v_pkg;

  r := core.fn_package_status(jsonb_build_object('package', v_pkg));
  IF (r->>'ok')::boolean OR r->>'reason' <> 'not_installed' THEN RAISE EXCEPTION 'FAIL [fehlt -> not_installed] %', r; END IF;

  INSERT INTO core.package_registry (package, version, status) VALUES (v_pkg, '1.0.0', 'installing');
  r := core.fn_package_status(jsonb_build_object('package', v_pkg));
  IF (r->>'ok')::boolean OR r->>'reason' <> 'incomplete' THEN RAISE EXCEPTION 'FAIL [installing -> incomplete] %', r; END IF;
  UPDATE core.package_registry SET status = 'installed' WHERE package = v_pkg;
  r := core.fn_package_status(jsonb_build_object('package', v_pkg));
  IF (r->>'ok')::boolean OR r->>'reason' <> 'incomplete' THEN RAISE EXCEPTION 'FAIL [installed -> incomplete] %', r; END IF;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = v_pkg;
  r := core.fn_package_status(jsonb_build_object('package', v_pkg));
  IF (r->>'ok')::boolean OR r->>'reason' <> 'inactive' THEN RAISE EXCEPTION 'FAIL [inactive] %', r; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = v_pkg;
  r := core.fn_package_status(jsonb_build_object('package', v_pkg));
  IF NOT (r->>'ok')::boolean OR r->>'status' <> 'active' THEN RAISE EXCEPTION 'FAIL [active -> ok] %', r; END IF;

  -- Fehlender/leerer Paketname -> {ok:false, reason:'package_required'} statt Exception.
  r := core.fn_package_status('{}'::jsonb);
  IF (r->>'ok')::boolean OR r->>'reason' <> 'package_required' THEN RAISE EXCEPTION 'FAIL [ohne package] %', r; END IF;

  -- is_owner: nicht-numerische chat_id (Test-Harness 'test_…') und fehlende chat_id -> false, nie Exception.
  r := core.fn_package_status(jsonb_build_object('package', v_pkg, 'chat_id', 'test_harness_1'));
  IF (r->>'is_owner')::boolean THEN RAISE EXCEPTION 'FAIL [nicht-numerisch -> owner] %', r; END IF;
  r := core.fn_package_status(jsonb_build_object('package', v_pkg));
  IF (r->>'is_owner')::boolean THEN RAISE EXCEPTION 'FAIL [ohne chat_id -> owner] %', r; END IF;
  -- unbekannte numerische chat_id -> false
  r := core.fn_package_status(jsonb_build_object('package', v_pkg, 'chat_id', '999999999999'));
  IF (r->>'is_owner')::boolean THEN RAISE EXCEPTION 'FAIL [fremd -> owner] %', r; END IF;

  RAISE NOTICE 'PASS core.fn_package_status [Status-Matrix + is_owner-Guards]';
END $$;

ROLLBACK;
