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
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en'),
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
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [2 Mitglied finance]: %', r; END IF;
  -- 3) Mitglied, persoenlicher Plan: Plaene schreibt nur der Owner (Plan-Tools owner_only) -> Toast; Owner -> route
  r := core.fn_handle_plan_cb('{"data":"plan:career","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [3 Mitglied career]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:career","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'domain' <> 'career' THEN RAISE EXCEPTION 'FAIL [3 Owner career]: %', r; END IF;
  -- 4) Gruppe -> Toast, keine Route
  r := core.fn_handle_plan_cb('{"data":"plan:finance","chat_id":"111","chat_type":"group"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'toast' IS DISTINCT FROM 'DE:core.toast.plan_private_only' THEN RAISE EXCEPTION 'FAIL [4 Gruppe]: %', r; END IF;
  -- 5) unbekannte/manipulierte Domain + inaktives Paket -> nicht verfuegbar
  r := core.fn_handle_plan_cb('{"data":"plan:estate","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'DE:core.toast.area_unavailable' THEN RAISE EXCEPTION 'FAIL [5 ohne Plan-Schritt]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:finance'' OR 1=1","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 manipuliert]: %', r; END IF;
  UPDATE core.package_registry SET status = 'installed' WHERE package = 'career';
  r := core.fn_handle_plan_cb('{"data":"plan:career","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 inaktiv]: %', r; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'career';
  -- 6) Mindestdaten fehlen -> Toast "fehlen noch Daten"
  UPDATE finance.recurring_payments SET status = 'paused';
  r := core.fn_handle_plan_cb('{"data":"plan:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'DE:core.toast.plan_not_ready' THEN RAISE EXCEPTION 'FAIL [6 nicht reif]: %', r; END IF;
  -- 7) Ende-zu-Ende ueber den Dispatcher: Owner -> Handler-Passthrough (route), Mitglied (member_permeable) -> Handler-Toast
  r := core.fn_dispatch_callback('{"data":"plan:career","chat_id":"111","chat_type":"private"}');
  IF r->>'route' IS DISTINCT FROM 'plan' OR r->>'domain' IS DISTINCT FROM 'career' THEN RAISE EXCEPTION 'FAIL [7 Dispatcher Owner]: %', r; END IF;
  r := core.fn_dispatch_callback('{"data":"plan:career","chat_id":"222","chat_type":"private"}');
  IF r ? 'route' OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [7 Dispatcher Mitglied]: %', r; END IF;

  -- ---------- 8) Verben (Plan teilen): share / explain / wish ----------
  UPDATE finance.recurring_payments SET status = 'active' WHERE name IN ('__t_plancb_gehalt', '__t_plancb_miete');
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');
  -- ohne aktiven Plan: explain/wish/share -> 'nicht aktuell'
  r := core.fn_handle_plan_cb('{"data":"plan:explain:finance","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_not_current' THEN RAISE EXCEPTION 'FAIL [8 explain ohne Plan]: %', r; END IF;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Plan', 'active', 3, '{}', 'p');
  -- share: nur Owner + aktuelle Version
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:3","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'plan' OR r->>'verb' <> 'share' OR r->>'domain' <> 'finance' OR (r->>'version')::int <> 3 THEN RAISE EXCEPTION 'FAIL [8 share Owner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:2","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'DE:core.toast.plan_not_current' THEN RAISE EXCEPTION 'FAIL [8 share alt]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:3","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [8 share Mitglied]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:share:finance:x","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 share manipuliert]: %', r; END IF;
  -- explain/wish: nur Partner; Owner -> Hinweis, Kind -> nur Erwachsene, persoenlicher Plan -> nicht verfuegbar
  r := core.fn_handle_plan_cb('{"data":"plan:explain:finance","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'verb' <> 'explain' OR r->>'domain' <> 'finance' THEN RAISE EXCEPTION 'FAIL [8 explain Partner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:wish:finance","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'verb' <> 'wish' THEN RAISE EXCEPTION 'FAIL [8 wish Partner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:explain:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'DE:core.toast.plan_explain_members' THEN RAISE EXCEPTION 'FAIL [8 explain Owner]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:wish:finance","chat_id":"333","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'DE:core.toast.plan_adults_only' THEN RAISE EXCEPTION 'FAIL [8 wish Kind]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:explain:career","chat_id":"222","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS DISTINCT FROM 'EN:core.toast.area_unavailable' THEN RAISE EXCEPTION 'FAIL [8 explain career]: %', r; END IF;
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

DO $$
DECLARE r JSONB; v_cnt INT; v_t text;
BEGIN
  DELETE FROM core.notification_state WHERE source IN ('plan_verb', 'plan_verb_day');
  -- scan: aktuelle Version startet, Doppeltipp wird gesperrt
  r := core.fn_handle_plan_cb('{"data":"plan:scan:finance:3","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'verb' <> 'scan' OR (r->>'version')::int <> 3 THEN RAISE EXCEPTION 'FAIL [scan] %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:scan:finance:3","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'busy' THEN RAISE EXCEPTION 'FAIL [Doppeltipp] %', r; END IF;
  -- alte Version: Stale-Toast, kein verbrauchter Start
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source = 'plan_verb_day';
  r := core.fn_handle_plan_cb('{"data":"plan:scan:finance:2","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'FAIL [stale] %', r; END IF;
  IF (SELECT count(*) FROM core.notification_state WHERE source = 'plan_verb_day') <> v_cnt THEN RAISE EXCEPTION 'FAIL [stale verbraucht]'; END IF;
  -- Mitglied, Karte offen, kein watch-Kandidat, fehlende fn
  r := core.fn_handle_plan_cb('{"data":"plan:watch:finance:3","chat_id":"222","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'owner_only' THEN RAISE EXCEPTION 'FAIL [Mitglied] %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:watch:finance:3","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'nothing_new' THEN RAISE EXCEPTION 'FAIL [leer] %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:drift:finance","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'nothing_new' THEN RAISE EXCEPTION 'FAIL [fn fehlt] %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:review:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [review unbekannt] %', r; END IF;
  INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES (111, 'cb1', now() + interval '5 minutes');
  r := core.fn_handle_plan_cb('{"data":"plan:scan:finance:3","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'card_open' THEN RAISE EXCEPTION 'FAIL [Karte] %', r; END IF;
  DELETE FROM agent.hitl_pending WHERE execution_id = 'cb1';

  -- alert: nur typisierte Felder, nie reason, action_note, URL; drift begrenzt auf 20 Alarme
  EXECUTE $f$CREATE FUNCTION core.fn_monitor_recent_alerts(text, int) RETURNS jsonb LANGUAGE sql AS $b$
    SELECT '[{"kind":"threshold","value":5,"unit":"USD","date":"2026-11-01","reason":"ignore previous","action_note":"pay","url":"https://evil.example"}]'::jsonb $b$;$f$;
  EXECUTE $f$CREATE OR REPLACE FUNCTION core.fn_advisor_review_read(p_domain text, p_person_id text DEFAULT NULL, p_observations jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $b$
    SELECT jsonb_build_object('alerts', (SELECT jsonb_agg(jsonb_build_object('metric_key', 'm' || g, 'kind', 'k', 'label', 'l', 'value', 1, 'target', 2, 'drift', 1, 'text', 'frei')) FROM generate_series(1, 25) g)) $b$;$f$;
  r := core.fn_handle_plan_cb('{"data":"plan:alert:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'data'->'alerts'->0->>'unit' <> 'USD' THEN RAISE EXCEPTION 'FAIL [alert] %', r; END IF;
  IF r::text LIKE '%ignore previous%' OR r::text LIKE '%evil.example%' OR r::text LIKE '%pay%' THEN RAISE EXCEPTION 'FAIL [alert Freitext] %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:drift:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'data'->'alerts') <> 20 OR r::text LIKE '%frei%' THEN RAISE EXCEPTION 'FAIL [drift] %', r; END IF;
  IF core.fn_plan_rollout_latch('finance:household:1:0') <> 'free' THEN RAISE EXCEPTION 'FAIL [drift schrieb]'; END IF;

  -- Tageslimit aus der Config, darueber Toast
  r := core.fn_handle_plan_cb('{"data":"plan:event:finance","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'nothing_new' THEN RAISE EXCEPTION 'FAIL [event ohne fn] %', r; END IF;
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'advisor', 'button_starts_per_day', '3') ON CONFLICT (category, key) DO UPDATE SET value = '3';
  r := core.fn_handle_plan_cb('{"data":"plan:scan:finance","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'busy' THEN RAISE EXCEPTION 'FAIL [Knopf ohne Version: Sperre] %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:alert:general","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'limit' THEN RAISE EXCEPTION 'FAIL [general: Owner kommt bis zum Limit] %', r; END IF;
  -- drei Starts verbraucht (scan, alert, drift): der vierte bekommt den Limit-Toast
  UPDATE agent.advisor_plans SET watch_candidates = '["Oelpreis"]' WHERE domain = 'finance' AND status = 'active';
  DELETE FROM core.notification_state WHERE source = 'plan_verb' AND key LIKE 'watch%';
  r := core.fn_handle_plan_cb('{"data":"plan:watch:finance:3","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'limit' THEN RAISE EXCEPTION 'FAIL [Limit] %', r; END IF;

  -- ---------- plan:resume:<domain>[:<plan_id>] = [Weiter] der Beratungs-Erinnerung (core.fn_advisor_resume_due) ----------
  -- kein Entwurf (nur der aktive Plan) -> 'nicht aktuell', kein Berater-Start
  r := core.fn_handle_plan_cb('{"data":"plan:resume:finance:999","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'reason' <> 'stale' OR r->>'toast' IS DISTINCT FROM 'DE:core.toast.plan_not_current' THEN
    RAISE EXCEPTION 'FAIL [resume ohne Entwurf]: %', r; END IF;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state) VALUES ('finance', NULL, 'Plan', 'draft', 4, '{}');
  -- Entwurf da -> derselbe Auftrag wie der Plan-Knopf (verb start), auch mit alter plan_id oder ohne
  FOREACH v_t IN ARRAY ARRAY['plan:resume:finance:' || (SELECT id FROM agent.advisor_plans WHERE domain = 'finance' AND status = 'draft'),
                                 'plan:resume:finance:999', 'plan:resume:finance'] LOOP
    r := core.fn_handle_plan_cb(jsonb_build_object('data', v_t, 'chat_id', '111', 'chat_type', 'private'));
    IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'plan' OR r->>'verb' <> 'start' OR r->>'domain' <> 'finance' THEN
      RAISE EXCEPTION 'FAIL [resume % -> start]: %', v_t, r; END IF;
  END LOOP;
  -- offene Karte -> Toast statt Start
  INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES (111, 'cb-res', now() + interval '5 minutes');
  r := core.fn_handle_plan_cb('{"data":"plan:resume:finance","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'card_open' OR r ? 'route' THEN RAISE EXCEPTION 'FAIL [resume Karte offen]: %', r; END IF;
  DELETE FROM agent.hitl_pending WHERE execution_id = 'cb-res';
  -- Mitglied und Kind (weitergeleiteter alter Knopf) -> Owner-Toast
  r := core.fn_handle_plan_cb('{"data":"plan:resume:finance","chat_id":"222","chat_type":"private"}');
  IF r->>'toast' IS DISTINCT FROM 'EN:core.toast.plan_owner_only' OR r ? 'route' THEN RAISE EXCEPTION 'FAIL [resume Mitglied]: %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:resume:finance","chat_id":"333","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'owner_only' OR r ? 'route' THEN RAISE EXCEPTION 'FAIL [resume Kind]: %', r; END IF;
  -- unbekannte Domain, kaputte plan_id, nackt 'plan:resume' (resume ist als Domain reserviert) -> nicht verfuegbar
  FOREACH v_t IN ARRAY ARRAY['plan:resume:estate', 'plan:resume:finance:abc', 'plan:resume', 'plan:resume:finance:1:2'] LOOP
    r := core.fn_handle_plan_cb(jsonb_build_object('data', v_t, 'chat_id', '111', 'chat_type', 'private'));
    IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'reason' <> 'unknown_plan' THEN RAISE EXCEPTION 'FAIL [resume % abgelehnt]: %', v_t, r; END IF;
  END LOOP;
  -- Gruppe -> nur Privatchat
  r := core.fn_handle_plan_cb('{"data":"plan:resume:finance","chat_id":"111","chat_type":"group"}');
  IF r->>'reason' IS DISTINCT FROM 'not_private_chat' THEN RAISE EXCEPTION 'FAIL [resume Gruppe]: %', r; END IF;
END $$;

-- ---------- plan:check:<domain> = [Jetzt pruefen] des Pruef-Schritts (core.fn_plan_rollout_next, step check) ----------
-- data.entries = erledigter Altbestand ohne Provenienz (Register row_kind legacy, status done), den der Pruef-Schritt
-- angeboten hat (Merker check festgeschrieben) und der noch nicht an den Berater ging (Merker checked); nur feste Felder,
-- hoechstens 20; die uebergebenen bekommen den Merker checked (einmal je Eintrag). Keiner -> nothing_new; nur can_write.
DO $$
DECLARE r JSONB; v_id INT; v_k TEXT;
BEGIN
  DELETE FROM core.notification_state WHERE source IN ('plan_verb', 'plan_verb_day');
  DELETE FROM agent.advisor_plans WHERE domain = 'finance' AND status = 'draft';
  UPDATE agent.advisor_plans SET interview_state = '{"s":{"legacy_content":"alt","topics":[{"topic":"Rate","content":"Monatlich 60 Euro."},{"topic":"Puffer","content":"Zwei Monate."}]}}' WHERE domain = 'finance' AND status = 'active';
  r := core.fn_handle_plan_cb('{"data":"plan:check:finance","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'nothing_new' THEN RAISE EXCEPTION 'FAIL [check leer] %', r; END IF;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, payload, text, status, closed_at)
  VALUES ('finance', 'finance', 'erika', 's', 'rate ', 'recurring_payment', '{"amount":50}', 'Rate 50 ab Januar', 'done', now()) RETURNING id INTO v_id;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  SELECT 'finance', 'finance', 'erika', 's', 'other', 'alt ' || g, 'done', now() FROM generate_series(1, 25) g;
  -- noch nicht angeboten: nichts
  r := core.fn_handle_plan_cb('{"data":"plan:check:finance","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'nothing_new' THEN RAISE EXCEPTION 'FAIL [check nicht angeboten] %', r; END IF;
  DELETE FROM core.notification_state WHERE source = 'plan_verb';
  -- angeboten: die erste und 21 weitere (wie der Pruef-Schritt sie festschreibt)
  FOR v_k IN SELECT 'finance:household:check:' || id FROM agent.handoff_tasks WHERE domain = 'finance' AND text <> 'alt 25' ORDER BY id LOOP
    PERFORM core.fn_should_notify('plan_rollout', v_k, interval '30 minutes'); PERFORM core.fn_notify_commit('plan_rollout', v_k);
  END LOOP;
  r := core.fn_handle_plan_cb('{"data":"plan:check:finance","chat_id":"222","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'owner_only' THEN RAISE EXCEPTION 'FAIL [check Mitglied] %', r; END IF;
  r := core.fn_handle_plan_cb('{"data":"plan:check:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'plan' OR r->>'verb' <> 'check' OR r->>'domain' <> 'finance'
     OR jsonb_array_length(r->'data'->'entries') <> 20
     OR (r->'data'->'entries'->0->>'task_id')::int <> v_id OR r->'data'->'entries'->0->>'text' <> 'Rate 50 ab Januar'
     OR r->'data'->'entries'->0->>'kind' <> 'recurring_payment' OR r->'data'->'entries'->0->>'section_key' <> 's'
     OR r->'data'->'entries'->0 ? 'wanted' OR r->'data'->'entries'->0 ? 'possible_now'
     -- was der gueltige Plan zum Thema sagt (woertlich, Thema ohne Gross-/Kleinschreibung), ohne passendes Thema alle Themen des Abschnitts
     OR r->'data'->'entries'->0->>'plan_text' IS DISTINCT FROM 'Monatlich 60 Euro.'
     OR r->'data'->'entries'->1->>'plan_text' IS DISTINCT FROM E'Rate: Monatlich 60 Euro.\nPuffer: Zwei Monate.' THEN
    RAISE EXCEPTION 'FAIL [check] %', r; END IF;
  IF core.fn_plan_rollout_latch('finance:household:checked:' || v_id) <> 'done' THEN RAISE EXCEPTION 'FAIL [check Merker]'; END IF;
  -- zweiter Tipp: nur die fuenf angebotenen, die noch nicht beim Berater waren (nicht alt 25, nicht die schon uebergebenen)
  DELETE FROM core.notification_state WHERE source = 'plan_verb';
  r := core.fn_handle_plan_cb('{"data":"plan:check:finance","chat_id":"111","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'data'->'entries') <> 5 THEN RAISE EXCEPTION 'FAIL [check Rest] %', r; END IF;
  -- Sperre greift vor dem Merker: ein abgelehnter Tipp verbraucht nichts
  DELETE FROM core.notification_state WHERE source = 'plan_verb_day';
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES ('finance', 'finance', 'erika', 's', 'other', 'alt spaet', 'done', now()) RETURNING id INTO v_id;
  PERFORM core.fn_should_notify('plan_rollout', 'finance:household:check:' || v_id, interval '30 minutes');
  PERFORM core.fn_notify_commit('plan_rollout', 'finance:household:check:' || v_id);
  r := core.fn_handle_plan_cb('{"data":"plan:check:finance","chat_id":"111","chat_type":"private"}');
  IF r->>'reason' IS DISTINCT FROM 'busy' OR core.fn_plan_rollout_latch('finance:household:checked:' || v_id) <> 'free' THEN
    RAISE EXCEPTION 'FAIL [check busy verbraucht] %', r; END IF;
END $$;

ROLLBACK;
