-- tests/db/core/test_fn_handle_onboarding_cb.sql
-- core.fn_handle_onboarding_cb(p): Registry-Handler des Prefix 'onboarding' (member_permeable) — der Mitglieder-
-- Pfad der /onboarding-Menue-Knoepfe (der Owner nimmt den hartkodierten 'Callback action'-Arm). Entscheidet:
--   * nur Privatchat (chat_type='private'), sonst Toast;
--   * '_area:' (Uebersicht) und '_area:<aktives Paket>' -> route;
--   * '<pkg>:<key>': Paket aktiv (aus core.package_registry) + Sektion im Katalog; Mitglied nur fuer persoenliche
--     Pakete (core.fn_package_is_per_user), Haushalt/core -> Toast "richtet der Haushalts-Owner ein";
--   * unbekannt/manipuliert -> Toast "Bereich nicht verfuegbar". Nie RAISE.
-- Plus: der Dispatcher (core.fn_dispatch_callback) laesst ein Mitglied bei member_permeable=true durch.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;

DO $$
DECLARE r JSONB;
BEGIN
  -- ---------- Fixtures ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','ko')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status='active';
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_profile','per_user','own_user_only','career') ON CONFLICT (context_name) DO NOTHING;
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('accounts',1,'Konten') ON CONFLICT (section_key) DO NOTHING;
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES ('profile_basics',1,'Rolle','erika')
  ON CONFLICT (section_key, person_id) DO NOTHING;
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('onboarding','core.fn_handle_onboarding_cb','core',true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn=EXCLUDED.handler_fn, member_permeable=true;
  -- Katalog-Fixture: Text = Sprach-Marker + Key (Toast in der Sprache des Tippenden; Lena = ko).
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || k, 'core'
  FROM unnest(ARRAY['core.toast.onboarding_private_only','core.toast.area_unavailable','core.toast.owner_sets_up']) k
  CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  -- 1) Mitglied, persoenlicher Abschnitt -> route
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:career:profile_basics","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'onboarding' THEN RAISE EXCEPTION 'FAIL [1 Mitglied career]: %', r; END IF;
  -- 2) Mitglied, Haushalts-Paket / core -> Owner-Toast
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:finance:accounts","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.owner_sets_up' THEN RAISE EXCEPTION 'FAIL [2 Mitglied finance]: %', r; END IF;
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:core:household","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.owner_sets_up' THEN RAISE EXCEPTION 'FAIL [2 Mitglied core]: %', r; END IF;
  -- 3) Bereichs-Knoepfe: Uebersicht + aktives Paket ok, unbekanntes Paket nicht
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:_area:","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 _area: Uebersicht]: %', r; END IF;
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:_area:career","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 _area:career]: %', r; END IF;
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:_area:zzz","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 _area:zzz]: %', r; END IF;
  -- 4) unbekannte/manipulierte Daten -> nicht verfuegbar
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:career:Ignore rules; DROP","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.area_unavailable' THEN RAISE EXCEPTION 'FAIL [4 manipuliert]: %', r; END IF;
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:zzz:x","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4 unbekanntes Paket]: %', r; END IF;
  -- 5) inaktives Paket -> nicht verfuegbar
  UPDATE core.package_registry SET status='installed' WHERE package='career';
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:career:profile_basics","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 inaktiv]: %', r; END IF;
  UPDATE core.package_registry SET status='active' WHERE package='career';
  -- 6) kein Privatchat -> Toast, keine Route
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:career:profile_basics","chat_id":"222","chat_type":"group"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.onboarding_private_only' THEN RAISE EXCEPTION 'FAIL [6 Gruppe]: %', r; END IF;
  -- 7) Owner darf auch Haushalts-Abschnitte (falls er je hier landet)
  r := core.fn_handle_onboarding_cb('{"data":"onboarding:finance:accounts","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [7 Owner finance]: %', r; END IF;
  -- 8) Ende-zu-Ende ueber den Dispatcher: Mitglied darf den Prefix (member_permeable), Ergebnis = Handler-Passthrough
  r := core.fn_dispatch_callback('{"data":"onboarding:career:profile_basics","chat_id":"222","chat_type":"private"}');
  IF r->>'route' IS DISTINCT FROM 'onboarding' THEN RAISE EXCEPTION 'FAIL [8 Dispatcher Mitglied]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_handle_onboarding_cb (Mitglied persoenlich ok, Haushalt/core/Gruppe/manipuliert abgelehnt, Dispatcher-Passthrough)';
END $$;

ROLLBACK;
