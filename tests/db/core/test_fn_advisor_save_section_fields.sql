-- tests/db/core/test_fn_advisor_save_section_fields.sql
-- Thema = Entscheidung + Felder neben dem Text:
--   * why (<= 400) wird am Thema gespeichert, zu lang -> why_too_long;
--   * open_points: die DB vergibt Ids (fortlaufend je Entwurf), Text <= 200 (open_point_too_long), resolves schliesst
--     Punkte auch anderer Themen, unbekannte/schon geschlossene Id -> unknown_open_point; Rueckgabe open_points;
--   * core.fn_advisor_open_points listet die ungeschlossenen mit Abschnitt und Thema;
--   * replaces_topic ersetzt ein Thema unter neuer Bezeichnung an seiner Stelle (offene Aufgaben ziehen mit), unbekannt
--     -> unknown_topic + topics;
--   * mixed_script: ein Wort mit lateinischen und anderen Schriftzeichen in content/why/open_points/handoff text;
--   * core.fn_advisor_topic_index liefert die Themen je Abschnitt; core.fn_render_plan_text gibt den Text unveraendert zurueck.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r       jsonb;
  v_state jsonb;
  v_pid   int;
  v_op1   int;
  v_op2   int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM core.advisors WHERE domain = '__sf__';
  INSERT INTO core.advisors (domain, plan_context, review_fn, package) VALUES ('__sf__', '__sf___planning', 'finance.fn_advisor_review', 'core');
  DELETE FROM agent.advisor_plans WHERE domain = '__sf__';
  DELETE FROM agent.handoff_tasks WHERE domain = '__sf__';

  -- ---------- 1) why ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','Drei Monatsausgaben auf Tagesgeld.','why', repeat('w', 401)));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'why_too_long' THEN
    RAISE EXCEPTION 'FAIL [1 why_too_long]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','Drei Monatsausgaben auf Tagesgeld.','why','Faustregel der Beratung: drei Monate.'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 why ok]: %', r; END IF;
  v_pid := (r->>'plan_id')::int;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_pid;
  IF v_state->'emergency_reserve'->'topics'->0->>'why' IS DISTINCT FROM 'Faustregel der Beratung: drei Monate.' THEN
    RAISE EXCEPTION 'FAIL [1 why gespeichert]: %', v_state; END IF;
  RAISE NOTICE 'PASS [1 why]';

  -- ---------- 2) open_points: Ids, Laenge, Rueckgabe ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','retirement_pension',
         'topic','Betriebsrente','section_content','Betriebsrente bleibt, Hoehe klaeren wir.',
         'open_points', jsonb_build_array(repeat('o', 201))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'open_point_too_long' THEN
    RAISE EXCEPTION 'FAIL [2 open_point_too_long]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','retirement_pension',
         'topic','Betriebsrente','section_content','Betriebsrente bleibt.',
         'open_points', '["Stand der Betriebsrente erfragen", {"text":"Beitrag pruefen"}]'));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'open_points') <> 2 THEN
    RAISE EXCEPTION 'FAIL [2 open_points ok]: %', r; END IF;
  v_op1 := (r->'open_points'->0->>'id')::int;
  v_op2 := (r->'open_points'->1->>'id')::int;
  IF v_op1 IS NULL OR v_op2 <> v_op1 + 1 OR r->'open_points'->0->>'text' <> 'Stand der Betriebsrente erfragen' THEN
    RAISE EXCEPTION 'FAIL [2 Ids fortlaufend]: %', r; END IF;
  -- derselbe Text noch einmal (Vorschlag nach Anmerkung neu gesendet) -> kein zweiter Punkt
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','retirement_pension',
         'topic','Betriebsrente','section_content','Betriebsrente bleibt.','open_points', '[" stand der Betriebsrente erfragen"]'));
  IF jsonb_array_length(r->'open_points') <> 2 THEN RAISE EXCEPTION 'FAIL [2 keine Dublette]: %', r; END IF;
  -- ein erneuter Save desselben Themas ohne open_points laesst die offenen Punkte stehen
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','retirement_pension',
         'topic','Betriebsrente','section_content','Betriebsrente bleibt unveraendert.'));
  r := core.fn_advisor_open_points('__sf__', '111');
  IF jsonb_array_length(r) <> 2 OR r->0->>'section_key' <> 'retirement_pension' OR r->0->>'topic' <> 'Betriebsrente'
     OR (r->0->>'id')::int <> v_op1 THEN
    RAISE EXCEPTION 'FAIL [2 fn_advisor_open_points]: %', r; END IF;
  RAISE NOTICE 'PASS [2 open_points]';

  -- ---------- 3) resolves ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','goals_triggers',
         'topic','Ziele','section_content','Rente aufstocken nach Rueckmeldung.','resolves', jsonb_build_array(999)));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'unknown_open_point' THEN
    RAISE EXCEPTION 'FAIL [3 unknown_open_point]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','goals_triggers',
         'topic','Ziele','section_content','Rente aufstocken.','resolves', jsonb_build_array(v_op1)));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 resolves ok]: %', r; END IF;
  r := core.fn_advisor_open_points('__sf__', '111');
  IF jsonb_array_length(r) <> 1 OR (r->0->>'id')::int <> v_op2 THEN
    RAISE EXCEPTION 'FAIL [3 geschlossen]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','goals_triggers',
         'topic','Ziele','section_content','Rente aufstocken.','resolves', jsonb_build_array(v_op1)));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'unknown_open_point' THEN
    RAISE EXCEPTION 'FAIL [3 schon geschlossen]: %', r; END IF;
  -- neue Punkte bekommen nie eine schon vergebene Id
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','goals_triggers',
         'topic','Ziele','section_content','Rente aufstocken.','open_points', '["Termin finden"]'));
  IF (r->'open_points'->0->>'id')::int <= v_op2 THEN RAISE EXCEPTION 'FAIL [3 neue Id]: %', r; END IF;
  RAISE NOTICE 'PASS [3 resolves]';

  -- ---------- 4) replaces_topic ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Ruecklage','section_content','Rücklage für Auto.',
         'handoff_tasks', '[{"kind":"savings_goal","text":"Sparziel Auto anlegen"}]'));
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Auto','replaces_topic','Gibt es nicht','section_content','x'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'unknown_topic'
     OR NOT (r->'topics' @> '["Notgroschen","Ruecklage"]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [4 unknown_topic]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Autorücklage','replaces_topic','ruecklage','section_content','Eigenes Sparziel für das Auto.'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'topics' <> '["Notgroschen","Autorücklage"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4 ersetzt an der Stelle]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE domain = '__sf__' AND topic = 'Ruecklage')
     OR NOT EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE domain = '__sf__' AND topic = 'Autorücklage' AND status = 'open') THEN
    RAISE EXCEPTION 'FAIL [4 Aufgaben ziehen mit]'; END IF;
  RAISE NOTICE 'PASS [4 replaces_topic]';

  -- ---------- 5) mixed_script ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','Der Notgro세schen bleibt.'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'mixed_script' OR r->>'word' IS DISTINCT FROM 'Notgro세schen' THEN
    RAISE EXCEPTION 'FAIL [5 content]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','ok','why','Grund mit Wortмix'));
  IF r->>'code' IS DISTINCT FROM 'mixed_script' THEN RAISE EXCEPTION 'FAIL [5 why]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','ok','open_points','["Prüαfen"]'));
  IF r->>'code' IS DISTINCT FROM 'mixed_script' THEN RAISE EXCEPTION 'FAIL [5 open_points]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','ok','handoff_tasks','[{"kind":"other","text":"Kon中to anlegen"}]'));
  IF r->>'code' IS DISTINCT FROM 'mixed_script' THEN RAISE EXCEPTION 'FAIL [5 handoff]: %', r; END IF;
  -- getrennte Woerter verschiedener Schrift und angehaengte Endungen sind erlaubt (Originalsprache)
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sf__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','Notgroschen 비상금 bleibt auf Tagesgeld. ETF는 매달 App에서 이체.'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5 getrennte Woerter]: %', r; END IF;
  RAISE NOTICE 'PASS [5 mixed_script]';

  -- ---------- 6) topic_index + Anzeige-Haken ----------
  r := core.fn_advisor_topic_index('__sf__', '111');
  IF NOT (r @> '[{"section_key":"emergency_reserve","topic":"Autorücklage"},{"section_key":"goals_triggers","topic":"Ziele"}]'::jsonb)
     OR jsonb_array_length(r) <> 4 THEN
    RAISE EXCEPTION 'FAIL [6 topic_index]: %', r; END IF;
  IF core.fn_render_plan_text('Text [x]', 'de') IS DISTINCT FROM 'Text [x]' THEN
    RAISE EXCEPTION 'FAIL [6 fn_render_plan_text]'; END IF;
  RAISE NOTICE 'PASS [6 topic_index + fn_render_plan_text]';

  -- ---------- 7) Anbauten: Keys mit Praefix annex_ trotz festem Katalog ----------
  DELETE FROM core.advisors WHERE domain = '__sfk__';
  INSERT INTO core.advisors (domain, plan_context, review_fn, package) VALUES ('__sfk__', '__sfk___planning', 'finance.fn_advisor_review', 'estate');
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('estate.plan_section.basis', 'de', 'Basis', 'estate') ON CONFLICT (key, lang) DO NOTHING;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sfk__','chat_id','111','section_key','foo','section_content','x'));
  IF r->>'code' IS DISTINCT FROM 'unknown_section_key' THEN RAISE EXCEPTION 'FAIL [7 unbekannter Key]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__sfk__','chat_id','111','section_key','annex_beliefs','section_content','Wir sparen nachhaltig.'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [7 annex_]: %', r; END IF;
  RAISE NOTICE 'PASS [7 annex_]';
END $$;

ROLLBACK;
