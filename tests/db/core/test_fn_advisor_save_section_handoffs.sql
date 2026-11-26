-- tests/db/core/test_fn_advisor_save_section_handoffs.sql
-- agent.fn_advisor_save_section, vereinbarte Eintraege mit Grund, Rest und Vorpruefung (core.advisors.handoff_check_fn):
--   * why <= 160 an der Vormerkung; zu lang -> handoff_why_too_long ohne Write;
--   * rest <= 120 wird offener Punkt des Themas, open_point_id zeigt darauf (gleicher Text = derselbe Punkt); zu lang abgelehnt;
--   * Vorpruefung: Aufruf -> wanted; "geht noch nicht" -> deferred mit blocked_code und eigener Kartenzeile; mehrdeutig,
--     Wahl noetig -> ganzer Save abgelehnt mit task_index und Kandidaten bzw. Optionen; option waehlt; unbekannter Code
--     aus dem Paket abgelehnt; wirft die Paket-fn -> Eintrag ohne wanted (neutral);
--   * neuer Save ersetzt open und beim Vereinbaren zurueckgestellte, nicht die beim Eintragen zurueckgestellten.
BEGIN;

CREATE FUNCTION core.fn_t_precheck(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  CASE p->'payload'->>'t'
    WHEN 'unsupported' THEN RETURN '{"ok":true,"unsupported":true,"blocked_code":"end_date_future"}'::jsonb;
    WHEN 'unsupported_call' THEN RETURN '{"ok":true,"unsupported":true,"blocked_code":"end_date_future","call":{"tool":"create_savings_goal","input":{"name":"Rad"}}}'::jsonb;
    WHEN 'badcode' THEN RETURN '{"ok":true,"unsupported":true,"blocked_code":"no_such_code"}'::jsonb;
    WHEN 'ambiguous' THEN RETURN '{"ok":false,"code":"handoff_ref_ambiguous","reason":"two accounts match","candidates":[{"id":1,"label":"A"},{"id":2,"label":"B"}]}'::jsonb;
    WHEN 'choice' THEN
      IF p->>'option' = 'four' THEN RETURN '{"ok":true,"call":{"tool":"create_recurring_transfer","input":{"amount":500,"count":4}}}'::jsonb; END IF;
      RETURN '{"ok":false,"code":"handoff_choice_needed","reason":"pick one","options":[{"key":"four","label_key":"finance.x","recommended":true,"call":{}},{"key":"five","label_key":"finance.y","recommended":false,"call":{}}]}'::jsonb;
    WHEN 'throw' THEN RAISE EXCEPTION 'kaputt';
    WHEN 'other' THEN RETURN '{"ok":true}'::jsonb;
    ELSE RETURN jsonb_build_object('ok', true, 'call', jsonb_build_object('tool', 'create_savings_goal', 'input', p->'payload'));
  END CASE;
END $f$;

DO $$
DECLARE
  r     jsonb;
  v_n   int;
  v_op  int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE context_name = 'financial_planning';
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true);
  INSERT INTO core.ui_texts (key, lang, text, package)
  VALUES ('finance.handoff.blocked.end_date_future', 'de', 'Ende in der Zukunft geht noch nicht.', 'finance')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  DELETE FROM agent.handoff_tasks;
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';

  -- ---------- 1) why und rest ohne Vorpruefung ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','goals_triggers','topic','Rente',
         'section_content','Betriebsrente aufnehmen.',
         'handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','Betriebsrente eintragen','why',repeat('w',161)))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_why_too_long' OR EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain = 'finance') THEN
    RAISE EXCEPTION 'FAIL [1 why lang]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','goals_triggers','topic','Rente',
         'section_content','Betriebsrente aufnehmen.',
         'handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','Betriebsrente eintragen','rest',repeat('r',121)))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_rest_too_long' THEN RAISE EXCEPTION 'FAIL [1 rest lang]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','goals_triggers','topic','Rente',
         'section_content','Betriebsrente aufnehmen.', 'open_points', jsonb_build_array('Zweites Depot klaeren'),
         'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','other','text','Betriebsrente eintragen','why','Damit die Rentenluecke stimmt.','rest','Betrag, sobald der Anbieter sich meldet'),
            jsonb_build_object('kind','other','text','Depot zuordnen','rest','zweites depot klaeren'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'handoff_task_ids') <> 2 OR (r->>'handoffs_deferred')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [1 save]: %', r; END IF;
  IF (SELECT why FROM agent.handoff_tasks WHERE text = 'Betriebsrente eintragen') <> 'Damit die Rentenluecke stimmt.' THEN RAISE EXCEPTION 'FAIL [1 why]'; END IF;
  SELECT open_point_id INTO v_op FROM agent.handoff_tasks WHERE text = 'Betriebsrente eintragen';
  IF v_op IS NULL OR NOT EXISTS (SELECT 1 FROM agent.advisor_plans ap, core.fn_plan_open_points(ap.interview_state) o
                                  WHERE ap.domain = 'finance' AND o.id = v_op AND o.text = 'Betrag, sobald der Anbieter sich meldet' AND o.topic = 'Rente') THEN
    RAISE EXCEPTION 'FAIL [1 rest als offener Punkt]: %', (SELECT interview_state FROM agent.advisor_plans WHERE domain = 'finance'); END IF;
  -- gleicher Text wie ein offener Punkt (ohne Gross-/Kleinschreibung) -> derselbe Punkt, kein zweiter
  IF (SELECT open_point_id FROM agent.handoff_tasks WHERE text = 'Depot zuordnen')
     IS DISTINCT FROM (SELECT o.id FROM agent.advisor_plans ap, core.fn_plan_open_points(ap.interview_state) o
                        WHERE ap.domain = 'finance' AND o.text = 'Zweites Depot klaeren') THEN RAISE EXCEPTION 'FAIL [1 rest doppelt]'; END IF;
  IF (SELECT count(*) FROM agent.advisor_plans ap, core.fn_plan_open_points(ap.interview_state) o WHERE ap.domain = 'finance') <> 2 THEN
    RAISE EXCEPTION 'FAIL [1 Zahl offener Punkte]'; END IF;
  IF jsonb_path_exists(r->'open_points', '$[*] ? (@.text == "Betrag, sobald der Anbieter sich meldet")') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1 Rueckgabe open_points]: %', r; END IF;
  IF (SELECT wanted FROM agent.handoff_tasks WHERE text = 'Betriebsrente eintragen') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1 wanted ohne Vorpruefung]'; END IF;
  RAISE NOTICE 'PASS [1 why und rest]';

  -- ---------- 2) Vorpruefung ----------
  UPDATE core.advisors SET handoff_check_fn = 'core.fn_t_precheck' WHERE domain = 'finance';
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','wealth_building','topic','Ziele',
         'section_content','Ziele.',
         'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','savings_goal','payload',jsonb_build_object('name','Urlaub','target_amount',1200),'text','Sparziel Urlaub'),
            jsonb_build_object('kind','recurring_transfer','payload',jsonb_build_object('t','unsupported'),'text','Uebertrag bis Jahresende'),
            jsonb_build_object('kind','savings_goal','payload',jsonb_build_object('t','unsupported_call'),'text','Sparziel Rad unregelmaessig'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoffs_deferred')::int <> 2 THEN RAISE EXCEPTION 'FAIL [2 save]: %', r; END IF;
  -- geht noch nicht, aber der Aufruf liess sich bauen: das Soll wird trotzdem gespeichert
  IF (SELECT status || '/' || (wanted->>'tool') FROM agent.handoff_tasks WHERE text = 'Sparziel Rad unregelmaessig') IS DISTINCT FROM 'deferred/create_savings_goal'
     OR (SELECT wanted FROM agent.handoff_tasks WHERE text = 'Uebertrag bis Jahresende') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2 unsupported mit Aufruf]: %', (SELECT jsonb_agg(to_jsonb(t)) FROM agent.handoff_tasks t); END IF;
  IF (SELECT wanted FROM agent.handoff_tasks WHERE text = 'Sparziel Urlaub') <> '{"tool":"create_savings_goal","input":{"name":"Urlaub","target_amount":1200}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [2 wanted]: %', (SELECT wanted FROM agent.handoff_tasks WHERE text = 'Sparziel Urlaub'); END IF;
  IF (SELECT status || '/' || blocked_code FROM agent.handoff_tasks WHERE text = 'Uebertrag bis Jahresende') <> 'deferred/end_date_future' THEN
    RAISE EXCEPTION 'FAIL [2 deferred]'; END IF;
  IF NOT jsonb_path_exists(r->'card_lines', '$[*] ? (@.value == "core.hitl.handoff_planned_deferred" && @.params.text == "Uebertrag bis Jahresende")')
     OR NOT jsonb_path_exists(r->'card_lines', '$[*] ? (@.value == "core.hitl.handoff_planned" && @.params.text == "Sparziel Urlaub")') THEN
    RAISE EXCEPTION 'FAIL [2 Kartenzeilen]: %', r; END IF;
  RAISE NOTICE 'PASS [2 Vorpruefung: Aufruf und zurueckgestellt]';

  -- ---------- 3) Ablehnungen der Vorpruefung: kein Write ----------
  SELECT count(*) INTO v_n FROM agent.handoff_tasks;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Konten',
         'section_content','x', 'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','other','text','ok eins'),
            jsonb_build_object('kind','recurring_transfer','payload',jsonb_build_object('t','ambiguous'),'text','Uebertrag vom Sparkonto'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_ref_ambiguous' OR (r->>'task_index')::int <> 2
     OR jsonb_array_length(r->'candidates') <> 2 THEN RAISE EXCEPTION 'FAIL [3 mehrdeutig]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Konten',
         'section_content','x', 'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','recurring_transfer','payload',jsonb_build_object('t','choice'),'text','Raten bis zum Ziel'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_choice_needed' OR jsonb_array_length(r->'options') <> 2 THEN
    RAISE EXCEPTION 'FAIL [3 Wahl]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Konten',
         'section_content','x', 'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','recurring_transfer','payload',jsonb_build_object('t','badcode'),'text','Ungueltig'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'unknown_blocked_code' THEN RAISE EXCEPTION 'FAIL [3 Code]: %', r; END IF;
  IF (SELECT count(*) FROM agent.handoff_tasks) <> v_n OR EXISTS (SELECT 1 FROM agent.advisor_plans WHERE interview_state ? 'risk_profile') THEN
    RAISE EXCEPTION 'FAIL [3 trotzdem geschrieben]'; END IF;
  -- die Wahl des Nutzers (option) liefert den Aufruf
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Konten',
         'section_content','x', 'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','recurring_transfer','payload',jsonb_build_object('t','choice'),'option','four','text','Raten bis zum Ziel'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT wanted->'input'->>'count' FROM agent.handoff_tasks WHERE text = 'Raten bis zum Ziel') <> '4' THEN
    RAISE EXCEPTION 'FAIL [3 option]: %', r; END IF;
  -- Paket-fn wirft -> neutral: Eintrag ohne wanted; Art other ohne Aufruf ebenso
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','household_basics','topic','Allgemein',
         'section_content','x', 'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','other','payload',jsonb_build_object('t','throw'),'text','Wirft'),
            jsonb_build_object('kind','other','payload',jsonb_build_object('t','other'),'text','Ohne Werkzeug'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE text IN ('Wirft', 'Ohne Werkzeug') AND (wanted IS NOT NULL OR status <> 'open')) THEN
    RAISE EXCEPTION 'FAIL [3 neutral]: %', r; END IF;
  RAISE NOTICE 'PASS [3 Ablehnungen, Wahl, neutral]';

  -- ---------- 4) erneuter Save ersetzt open + beim Vereinbaren zurueckgestellte, nicht die beim Eintragen zurueckgestellten ----------
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, status, blocked_code, claimed_at)
  VALUES ('finance', 'finance', 'erika', 'wealth_building', 'Ziele', 'other', 'Beim Eintragen zurueckgestellt', 'deferred', 'end_date_future', now());
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','wealth_building','topic','Ziele',
         'section_content','Ziele neu.', 'handoff_tasks', '[]'));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE text IN ('Sparziel Urlaub', 'Uebertrag bis Jahresende', 'Sparziel Rad unregelmaessig'))
     OR NOT EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE text = 'Beim Eintragen zurueckgestellt') THEN
    RAISE EXCEPTION 'FAIL [4 ersetzen]: %', (SELECT jsonb_agg(to_jsonb(t)) FROM agent.handoff_tasks t); END IF;
  RAISE NOTICE 'PASS [4 ersetzen]';
END $$;

ROLLBACK;
