-- tests/db/core/test_fn_resolve_service.sql
-- paperless Phase 2: core.fn_resolve_service — die EINE Pruefstelle (PDP) des Core-Werkzeug-Vermittlers
--   agent.sub_dispatch_tool fuer Paket-Tool-Services ('<pkg>:<alias>' in core.services). Reihenfolge der Pruefung:
--   (1) Service-Zeile (fehlt/leere workflow_id -> unknown_service), (2) Paket nutzbar (core.fn_package_status ->
--   package_unavailable + reason + package_label), (3) Absender darf (permission je Service; adults_only/owner_only
--   ueber agent.fn_check_write_permission, Identitaet aus chat_id — nie vom LLM; all_members ohne Pruefung)
--   -> {ok:true, workflow_id, package}. Ablehnungen sind DATEN ({ok:false, error, reason}), nie RAISE.
--   Unaufgeloeste Absender (nicht-numerisch/leer/unbekannt) -> not_permitted/unresolved_sender, FAIL-CLOSED wie
--   core.fn_dispatch_callback (das Primitiv selbst ist dort fail-open und bekommt nur aufgeloeste Absender).
--   Self-contained: family-Fixture (owner 111, partner 222, child 333) + eigene Registry-/Service-Zeilen; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  r jsonb;
  v_pkg text := '__test_svcpkg__';
BEGIN
  -- ---------- Fixture ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222),
              jsonb_build_object('person_id','kid','first_name','Kim','last_name','Beispiel',
                                 'role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  DELETE FROM core.package_registry WHERE package = v_pkg;
  INSERT INTO core.package_registry (package, version, status, display_name) VALUES (v_pkg, '1.0.0', 'active', 'Testpaket');
  INSERT INTO core.services (name, workflow_id, package, permission) VALUES
    (v_pkg || ':adult_tool', 'wfAdult000000001', v_pkg, 'adults_only'),
    (v_pkg || ':owner_tool', 'wfOwner000000001', v_pkg, 'owner_only'),
    (v_pkg || ':all_tool',   'wfAll00000000001', v_pkg, 'all_members'),
    (v_pkg || ':no_id_tool', '',                 v_pkg, 'all_members');

  -- ---------- (1) unknown_service ----------
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':missing', 'chat_id', '111'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'unknown_service' THEN RAISE EXCEPTION 'FAIL [fehlender Service -> unknown_service] %', r; END IF;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':no_id_tool', 'chat_id', '111'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'unknown_service' THEN RAISE EXCEPTION 'FAIL [leere workflow_id -> unknown_service] %', r; END IF;
  r := core.fn_resolve_service('{}'::jsonb);
  IF (r->>'ok')::boolean OR r->>'error' <> 'unknown_service' THEN RAISE EXCEPTION 'FAIL [ohne service -> unknown_service] %', r; END IF;
  RAISE NOTICE 'PASS [unknown_service: fehlt / leere workflow_id / ohne service]';

  -- ---------- (3) Berechtigung je Stufe (Paket aktiv) ----------
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':adult_tool', 'chat_id', '111'));
  IF NOT (r->>'ok')::boolean OR r->>'workflow_id' <> 'wfAdult000000001' OR r->>'package' <> v_pkg THEN
    RAISE EXCEPTION 'FAIL [adults_only/owner -> ok + workflow_id] %', r; END IF;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':adult_tool', 'chat_id', '222'));
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [adults_only/partner -> ok] %', r; END IF;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':adult_tool', 'chat_id', '333'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'not_permitted' OR r->>'reason' <> 'adults_only' OR r ? 'workflow_id' THEN
    RAISE EXCEPTION 'FAIL [adults_only/child -> not_permitted ohne workflow_id] %', r; END IF;

  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':owner_tool', 'chat_id', '111'));
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [owner_only/owner -> ok] %', r; END IF;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':owner_tool', 'chat_id', '222'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'not_permitted' THEN RAISE EXCEPTION 'FAIL [owner_only/partner -> not_permitted] %', r; END IF;

  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':all_tool', 'chat_id', '333'));
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [all_members/child -> ok] %', r; END IF;

  -- FAIL-CLOSED fuer unaufgeloeste Absender (Paritaet core.fn_dispatch_callback: die rohe chat_id NIE an das
  -- fail-open-Primitiv geben) — gilt fuer JEDE Stufe, auch all_members (= jedes AUFGELOESTE Mitglied).
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':adult_tool', 'chat_id', 'test_harness_1'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'not_permitted' OR r->>'reason' <> 'unresolved_sender' THEN
    RAISE EXCEPTION 'FAIL [adults_only/non-numeric -> not_permitted/unresolved_sender] %', r; END IF;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':all_tool', 'chat_id', '999'));
  IF (r->>'ok')::boolean OR r->>'reason' <> 'unresolved_sender' THEN
    RAISE EXCEPTION 'FAIL [all_members/unbekannt -> unresolved_sender] %', r; END IF;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':owner_tool'));
  IF (r->>'ok')::boolean OR r->>'reason' <> 'unresolved_sender' THEN
    RAISE EXCEPTION 'FAIL [ohne chat_id -> unresolved_sender] %', r; END IF;
  RAISE NOTICE 'PASS [Berechtigung: adults_only owner/partner ok, child abgelehnt; owner_only; all_members; unaufgeloest fail-closed]';

  -- ---------- (2) package_unavailable (Paket-Pruefung VOR der Berechtigung) ----------
  UPDATE core.package_registry SET status = 'inactive' WHERE package = v_pkg;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':adult_tool', 'chat_id', '111'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'package_unavailable' OR r->>'reason' <> 'inactive'
     OR r->>'package' <> v_pkg OR r->>'package_label' <> 'Testpaket' OR NOT (r->>'is_owner')::boolean THEN
    RAISE EXCEPTION 'FAIL [inactive -> package_unavailable + reason/label/is_owner] %', r; END IF;
  UPDATE core.package_registry SET status = 'installing' WHERE package = v_pkg;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':adult_tool', 'chat_id', '222'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'package_unavailable' OR r->>'reason' <> 'incomplete' OR (r->>'is_owner')::boolean THEN
    RAISE EXCEPTION 'FAIL [installing -> package_unavailable/incomplete, is_owner=false] %', r; END IF;
  DELETE FROM core.package_registry WHERE package = v_pkg;
  r := core.fn_resolve_service(jsonb_build_object('service', v_pkg || ':adult_tool', 'chat_id', '111'));
  IF (r->>'ok')::boolean OR r->>'error' <> 'package_unavailable' OR r->>'reason' <> 'not_installed' OR r->>'package_label' <> v_pkg THEN
    RAISE EXCEPTION 'FAIL [nicht registriert -> not_installed, Label-Fallback = Paketname] %', r; END IF;
  RAISE NOTICE 'PASS [package_unavailable: inactive / incomplete / not_installed + Label + is_owner]';
END $$;

ROLLBACK;
