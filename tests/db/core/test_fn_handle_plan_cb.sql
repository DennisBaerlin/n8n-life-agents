-- tests/db/core/test_fn_handle_plan_cb.sql
-- core.fn_handle_plan_cb(p): Registry-Handler des Callback-Prefix 'plan' (member_permeable) — der Knopf
-- "Finanzplan erstellen/fortsetzen/vervollstaendigen/ueberpruefen" aus Onboarding-Menue und Fertig-Karte.
-- Entscheidet aus core.fn_advisor_plan_status (eine Adresse):
--   * nur Privatchat, sonst Toast;
--   * Domain mit Plan-Schritt + aktivem Paket, sonst Toast "nicht verfuegbar";
--   * can_write=false (Mitglied: Plaene schreibt nur der Owner) -> Toast "Plaene speichert nur der Owner";
--   * ready=false (Mindestdaten fehlen) -> Toast "fehlen noch Daten";
--   * sonst {ok:true, route:'plan', domain}. Nie RAISE.
BEGIN;

DO $$
DECLARE r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','ko'),
    jsonb_build_object('person_id','kim','first_name','Kim','last_name','B','role','child','birth_date','2014-03-01','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE context_name IN ('financial_planning', 'career_planning');
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning', 'per_user', 'own_user_only', 'career');
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, gaps_fn, readiness_fn) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true, 'finance.fn_plan_gap_count', 'finance.fn_plan_readiness'),
    ('career',  'career_planning',    'career.fn_advisor_review',  'agent.career_advisor',  'career',  true, NULL, NULL);
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('plan', 'core.fn_handle_plan_cb', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || k, 'core'
  FROM unnest(ARRAY['core.toast.plan_private_only','core.toast.area_unavailable','core.toast.plan_owner_only','core.toast.plan_not_ready',
                    'core.toast.plan_adults_only','core.toast.plan_not_current','core.toast.plan_explain_members']) k
  CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  -- Mindestdaten fuer finance herstellen (Konto + Einnahme + Ausgabe), unabhaengig vom Bestand
  WITH a AS (INSERT INTO finance.accounts (name, account_type) VALUES ('__t_plancb_giro', 'cash') RETURNING id)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  SELECT n, a.id, amt, 'month', 1, current_date - 40, current_date - 40 FROM a, (VALUES ('__t_plancb_gehalt', 2500), ('__t_plancb_miete', -900)) x(n, amt);

  -- 1) Owner, reif -> route plan + domain
  r := core.fn_handle_plan_cb('{"data":"plan:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'plan' OR r->>'domain' <> 'finance' THEN RAISE EXCEPTION 'FAIL [1 Owner]: %', r; END IF;
  -- 2) Mitglied am Haushalts-Plan -> Owner-Toast in seiner Sprache
  r := core.fn_handle_plan_cb('{"data":"plan:finance","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [2 Mitglied finance]: %', r; END IF;
  -- 3) Mitglied, persoenlicher Plan: Plaene schreibt nur der Owner (Plan-Tools owner_only) -> Toast; Owner -> route
  r := core.fn_handle_plan_cb('{"data":"plan:career","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [3 Mitglied career]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:career","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'domain' <> 'career' THEN RAISE EXCEPTION 'FAIL [3 Owner career]: %', r; END IF;
  -- 4) Gruppe -> Toast, keine Route
  r := core.fn_handle_plan_cb('{"data":"plan:finance","chat_id":"111","chat_type":"group"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_private_only' THEN RAISE EXCEPTION 'FAIL [4 Gruppe]: %', r; END IF;
  -- 5) unbekannte/manipulierte Domain + inaktives Paket -> nicht verfuegbar
  r := core.fn_handle_plan_cb('{"data":"plan:estate","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.area_unavailable' THEN RAISE EXCEPTION 'FAIL [5 ohne Plan-Schritt]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:finance'' OR 1=1","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 manipuliert]: %', r; END IF;
  UPDATE core.package_registry SET status = 'installed' WHERE package = 'career';
  r := core.fn_handle_plan_cb('{"data":"plan:career","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 inaktiv]: %', r; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'career';
  -- 6) Mindestdaten fehlen -> Toast "fehlen noch Daten"
  UPDATE finance.recurring_payments SET status = 'paused';
  r := core.fn_handle_plan_cb('{"data":"plan:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_not_ready' THEN RAISE EXCEPTION 'FAIL [6 nicht reif]: %', r; END IF;
  -- 7) Ende-zu-Ende ueber den Dispatcher: Owner -> Handler-Passthrough (route), Mitglied (member_permeable) -> Handler-Toast
  r := core.fn_dispatch_callback('{"data":"plan:career","chat_id":"111","chat_type":"private"}');
  IF r->>'route' IS DISTINCT FROM 'plan' OR r->>'domain' IS DISTINCT FROM 'career' THEN RAISE EXCEPTION 'FAIL [7 Dispatcher Owner]: %', r; END IF;
  r := core.fn_dispatch_callback('{"data":"plan:career","chat_id":"222","chat_type":"private"}');
  IF r ? 'route' OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [7 Dispatcher Mitglied]: %', r; END IF;

  -- ---------- 8) Verben (Plan teilen, 2026-10-28): share / explain / wish ----------
  UPDATE finance.recurring_payments SET status = 'active' WHERE name IN ('__t_plancb_gehalt', '__t_plancb_miete');
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');
  -- ohne aktiven Plan: explain/wish/share -> 'nicht aktuell'
  r := core.fn_handle_plan_cb('{"data":"plan:explain:finance","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.plan_not_current' THEN RAISE EXCEPTION 'FAIL [8 explain ohne Plan]: %', r; END IF;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Plan', 'active', 3, '{}', 'p');
  -- share: nur Owner + aktuelle Version
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:3","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'plan' OR r->>'verb' <> 'share' OR r->>'domain' <> 'finance' OR (r->>'version')::int <> 3 THEN RAISE EXCEPTION 'FAIL [8 share Owner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:2","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_not_current' THEN RAISE EXCEPTION 'FAIL [8 share alt]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:3","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [8 share Mitglied]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:x","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 share manipuliert]: %', r; END IF;
  -- explain/wish: nur Partner; Owner -> Hinweis, Kind -> nur Erwachsene, persoenlicher Plan -> nicht verfuegbar
  r := core.fn_handle_plan_cb('{"data":"plan:explain:finance","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'verb' <> 'explain' OR r->>'domain' <> 'finance' THEN RAISE EXCEPTION 'FAIL [8 explain Partner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:wish:finance","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'verb' <> 'wish' THEN RAISE EXCEPTION 'FAIL [8 wish Partner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:explain:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_explain_members' THEN RAISE EXCEPTION 'FAIL [8 explain Owner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:wish:finance","chat_id":"333","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_adults_only' THEN RAISE EXCEPTION 'FAIL [8 wish Kind]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:explain:career","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'KO:core.toast.area_unavailable' THEN RAISE EXCEPTION 'FAIL [8 explain career]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:wish:finance","chat_id":"222","chat_type":"group"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' THEN RAISE EXCEPTION 'FAIL [8 wish Gruppe]: %', r; END IF;
  -- Start-Format bleibt (plan:<domain>) und liefert verb start
  r := core.fn_handle_plan_cb('{"data":"plan:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'verb' <> 'start' THEN RAISE EXCEPTION 'FAIL [8 start verb]: %', r; END IF;
  -- Dispatcher-Passthrough fuer ein Mitglied (member_permeable)
  r := core.fn_dispatch_callback('{"data":"plan:explain:finance","chat_id":"222","chat_type":"private"}');
  IF r->>'verb' IS DISTINCT FROM 'explain' THEN RAISE EXCEPTION 'FAIL [8 Dispatcher explain]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_handle_plan_cb (Owner/Mitglied, persoenlich, Gruppe, ohne Plan-Schritt, inaktiv, nicht reif, Dispatcher, Verben share/explain/wish)';
END $$;

ROLLBACK;
