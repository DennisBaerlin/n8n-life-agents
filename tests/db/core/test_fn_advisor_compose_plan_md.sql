-- tests/db/core/test_fn_advisor_compose_plan_md.sql
-- Den Plan-Text setzt die DB zusammen (ein ein ganzer Plan passt nicht in eine
-- Modell-Antwort, das Veroeffentlichen lief in eine Schleife):
--   * agent.fn_advisor_compose_plan_md: Teile in der Reihenfolge von core.fn_advisor_parts (nicht alphabetisch), je Thema
--     Bezeichnung + Text + Warum + offene Punkte; Abschnitt ohne Themen ueber content bzw. legacy_content; ein Teil ohne
--     Inhalt steht sichtbar als "noch nicht besprochen" (keine stille Luecke); Abschnitte ausserhalb der Teile am Ende;
--   * agent.fn_advisor_publish_plan nimmt plan_md nicht mehr vom Modell (ein mitgeschicktes zaehlt nicht) und
--     veroeffentlicht auch einen Plan weit ueber 16k Tokens vollstaendig.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r      jsonb;
  v_plan int;
  v_md   text;
  i      int;
  j      int;
  k      text;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM core.advisors WHERE domain IN ('__cp__', '__cpbig__');
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, stages) VALUES
    ('__cp__', '__cp___planning', 'finance.fn_advisor_review', 'agent.cp_advisor', 'core',
     '[{"key":"a","sections":["goals_triggers","emergency_reserve"]},{"key":"b","sections":["debts_loans"]}]'),
    ('__cpbig__', '__cpbig___planning', 'finance.fn_advisor_review', 'agent.cp_advisor', 'core',
     '[{"key":"all","sections":["s1","s2","s3","s4","s5","s6","s7","s8","s9"]}]');
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT kk, 'de', 'DE:' || kk || CASE WHEN kk IN ('core.plan_md.why','core.plan_md.open_point') THEN ' {text}'
                                       WHEN kk IN ('core.plan_md.date_line','core.plan_md.date_deadline') THEN ' {date} {label}' ELSE '' END, 'core'
  FROM unnest(ARRAY['core.plan_md.why','core.plan_md.open_point','core.plan_md.part_open','core.plan_md.footer',
                    'core.plan_md.dates_head','core.plan_md.date_line','core.plan_md.date_deadline']) kk
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  DELETE FROM agent.advisor_plans WHERE domain IN ('__cp__', '__cpbig__');

  -- ---------- 1) Reihenfolge, Felder, fehlender Teil ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__cp__','chat_id','111','plan_name','Familienplan',
         'section_key','emergency_reserve','topic','Notgroschen','section_content','Drei Monatsausgaben.',
         'why','Faustregel der Beratung.','open_points','["Konto wählen"]'));
  v_plan := (r->>'plan_id')::int;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__cp__','chat_id','111','section_key','goals_triggers',
         'topic','Ziele','section_content','Rente aufstocken.'));
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__cp__','chat_id','111','section_key','zz_extra',
         'section_content','Sonderteil ohne Themen.'));
  v_md := agent.fn_advisor_compose_plan_md(v_plan);
  IF v_md NOT LIKE '# Familienplan%' THEN RAISE EXCEPTION 'FAIL [1 Titel]: %', v_md; END IF;
  IF position('Rente aufstocken.' IN v_md) = 0 OR position('Drei Monatsausgaben.' IN v_md) = 0
     OR position('Rente aufstocken.' IN v_md) > position('Drei Monatsausgaben.' IN v_md) THEN
    RAISE EXCEPTION 'FAIL [1 Reihenfolge der Teile]: %', v_md; END IF;
  IF position('### Notgroschen' IN v_md) = 0 OR position('DE:core.plan_md.why Faustregel der Beratung.' IN v_md) = 0
     OR position('DE:core.plan_md.open_point Konto wählen' IN v_md) = 0 THEN
    RAISE EXCEPTION 'FAIL [1 Thema mit Warum und Offen]: %', v_md; END IF;
  IF position('DE:core.plan_md.part_open' IN v_md) = 0 OR position('DE:core.plan_md.part_open' IN v_md) < position('Drei Monatsausgaben.' IN v_md) THEN
    RAISE EXCEPTION 'FAIL [1 fehlender Teil sichtbar]: %', v_md; END IF;
  IF position('Sonderteil ohne Themen.' IN v_md) < position('DE:core.plan_md.part_open' IN v_md) OR v_md NOT LIKE '%DE:core.plan_md.footer%' THEN
    RAISE EXCEPTION 'FAIL [1 Abschnitt ausserhalb der Teile am Ende + Hinweis]: %', v_md; END IF;
  -- Alt-Text ohne Themen
  UPDATE agent.advisor_plans SET interview_state = interview_state || '{"debts_loans":{"legacy_content":"Alter Kredit-Text."}}' WHERE id = v_plan;
  v_md := agent.fn_advisor_compose_plan_md(v_plan);
  IF position('Alter Kredit-Text.' IN v_md) = 0 OR position('DE:core.plan_md.part_open' IN v_md) > 0 THEN
    RAISE EXCEPTION 'FAIL [1 legacy_content]: %', v_md; END IF;
  -- Termine aus den beim Veroeffentlichen uebergebenen reminders: eigener Abschnitt in Datums-Reihenfolge, Fristen mit "bis"
  v_md := agent.fn_advisor_compose_plan_md(v_plan, '[{"label":"Plan durchsehen","remind_on":"2031-11-01"},{"label":"Testament hinterlegen","remind_on":"2030-06-30","deadline":true},{"label":"kaputt","remind_on":"bald"}]'::jsonb);
  IF position('## DE:core.plan_md.dates_head' IN v_md) = 0
     OR v_md !~ 'DE:core\.plan_md\.date_deadline \S*2030\S* Testament hinterlegen'
     OR v_md !~ 'DE:core\.plan_md\.date_line \S*2031\S* Plan durchsehen'
     OR position('Testament hinterlegen' IN v_md) > position('Plan durchsehen' IN v_md)
     OR position('kaputt' IN v_md) > 0 OR position('## DE:core.plan_md.dates_head' IN v_md) > position('DE:core.plan_md.footer' IN v_md) THEN
    RAISE EXCEPTION 'FAIL [1 Termine]: %', replace(v_md, E'\n', ' | '); END IF;
  IF position('dates_head' IN agent.fn_advisor_compose_plan_md(v_plan, '[]'::jsonb)) > 0 THEN RAISE EXCEPTION 'FAIL [1 ohne Termine kein Abschnitt]'; END IF;
  RAISE NOTICE 'PASS [1 Zusammensetzen]';

  -- ---------- 2) Publish nimmt kein plan_md vom Modell ----------
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__cp__','chat_id','111','plan_md','# Vom Modell geschrieben',
         'reminders','[{"label":"Plan durchsehen","remind_on":"2031-11-01"}]'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [2 publish]: %', r; END IF;
  SELECT plan_md INTO v_md FROM agent.advisor_plans WHERE id = v_plan;
  IF v_md LIKE '%Vom Modell geschrieben%' OR v_md NOT LIKE '# Familienplan%' OR v_md NOT LIKE '%Plan durchsehen%' THEN RAISE EXCEPTION 'FAIL [2 plan_md aus der DB]: %', v_md; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__cp__','chat_id','111'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 ohne Entwurf]: %', r; END IF;
  RAISE NOTICE 'PASS [2 Publish ohne plan_md]';

  -- ---------- 3) Grosser Plan weit ueber 16k Tokens (Regressions-Beleg) ----------
  FOR i IN 1..9 LOOP
    k := 's' || i;
    FOR j IN 1..9 LOOP
      r := agent.fn_advisor_save_section(jsonb_build_object('domain','__cpbig__','chat_id','111','section_key',k,
             'topic','Thema ' || j, 'section_content', 'Regel ' || i || '.' || j || ': ' || repeat('Entscheidung mit Grund. ', 37)));
      IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 save %/%]: %', i, j, r; END IF;
    END LOOP;
  END LOOP;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__cpbig__','chat_id','111'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 publish gross]: %', r; END IF;
  SELECT plan_md INTO v_md FROM agent.advisor_plans WHERE domain = '__cpbig__' AND status = 'active';
  IF length(v_md) < 70000 OR position('Regel 9.9:' IN v_md) = 0 OR position('Regel 1.1:' IN v_md) = 0 THEN
    RAISE EXCEPTION 'FAIL [3 vollstaendig]: Laenge %', length(v_md); END IF;
  RAISE NOTICE 'PASS [3 grosser Plan: % Zeichen]', length(v_md);
END $$;

ROLLBACK;
