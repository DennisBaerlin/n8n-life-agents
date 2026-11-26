-- tests/db/core/test_fn_advisor_propose_topics.sql
-- Themen-Vorschlag als offene Frage (Art topic):
--   * agent.fn_advisor_propose_topics: Probelauf aller Themen ueber agent.fn_advisor_save_section (nichts gespeichert, auch
--     kein Entwurf), Ablehnung kommt mit topic_index zurueck und legt keine Zeile an; je Thema eine Karte (Stapel) oder mit
--     one_card eine; zu lange Karte -> too_long; ein neuer Vorschlag ersetzt die offene Themen-Karte samt Rest ihres Stapels;
--   * Karten-Spezifikation: Kopf "Teil k von m", Fakten-Platzhalter nur auf der ersten Karte, Text, Warum, Eintragen, Offen;
--   * agent.fn_prompt_answer_topic (Tipp accept): speichert genau die Themen der Zeile, then next solange der Stapel weiterlaeuft,
--     danach continue (Auftrag an den Berater); scheitert das Speichern -> nichts gespeichert, Zeile superseded, continue.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r     jsonb;
  v_ids jsonb;
  v_p1  bigint;
  v_p2  bigint;
  v_st  jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM core.advisors WHERE domain = '__pt__';
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, stages) VALUES
    ('__pt__', '__pt___planning', 'finance.fn_advisor_review', 'agent.pt_advisor', 'core',
     '[{"key":"basis","sections":["household_basics","emergency_reserve"]},{"key":"ziele","sections":["goals_triggers"]}]');
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('q', 'core.fn_answer_chat_prompt', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;
  DELETE FROM agent.advisor_plans WHERE domain = '__pt__';
  DELETE FROM agent.chat_prompts;

  -- ---------- 1) Ablehnung im Probelauf ----------
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','emergency_reserve',
         'topics', jsonb_build_array(
            jsonb_build_object('topic','Notgroschen','content','Drei Monatsausgaben.'),
            jsonb_build_object('topic','Ort','content','Auf dem Tages세geld.'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'mixed_script' OR (r->>'topic_index')::int <> 2 THEN
    RAISE EXCEPTION 'FAIL [1 Ablehnung]: %', r; END IF;
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','222','section_key','emergency_reserve',
         'topics', '[{"topic":"Notgroschen","content":"Drei Monatsausgaben."}]'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 Mitglied]: %', r; END IF;
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','emergency_reserve',
         'topics', '[]'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'invalid_topics' THEN RAISE EXCEPTION 'FAIL [1 leer]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.chat_prompts) OR EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain = '__pt__') THEN
    RAISE EXCEPTION 'FAIL [1 Ablehnung schrieb]'; END IF;
  RAISE NOTICE 'PASS [1 Ablehnung]';

  -- ---------- 2) zwei Karten, nichts gespeichert ----------
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','emergency_reserve',
         'topics', jsonb_build_array(
            jsonb_build_object('topic','Notgroschen','content','Drei Monatsausgaben auf Tagesgeld.','why','Faustregel der Beratung.',
                               'handoff_tasks', '[{"kind":"savings_goal","text":"Sparziel Notgroschen"}]'),
            jsonb_build_object('topic','Auffüllen','content','Auffüllen vor dem Sparen.','open_points','["Betrag klären"]'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'cards')::int <> 2 OR jsonb_array_length(r->'prompt_ids') <> 2 THEN
    RAISE EXCEPTION 'FAIL [2 ok]: %', r; END IF;
  v_ids := r->'prompt_ids';
  v_p1 := (v_ids->>0)::bigint; v_p2 := (v_ids->>1)::bigint;
  IF EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain = '__pt__') OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE domain = '__pt__') THEN
    RAISE EXCEPTION 'FAIL [2 Probelauf speicherte]'; END IF;
  IF (SELECT count(DISTINCT batch_id) FROM agent.chat_prompts) <> 1
     OR (SELECT string_agg(kind || ':' || status || ':' || agent || ':' || ord, ',' ORDER BY ord) FROM agent.chat_prompts)
        <> 'topic:queued:agent.pt_advisor:1,topic:queued:agent.pt_advisor:2' THEN
    RAISE EXCEPTION 'FAIL [2 Zeilen]'; END IF;
  SELECT card INTO v_st FROM agent.chat_prompts WHERE id = v_p1;
  IF v_st->'lines'->0->>'key' <> 'core.prompt.topic_head' OR (v_st->'lines'->0->'params'->>'k')::int <> 2
     OR (v_st->'lines'->0->'params'->>'m')::int <> 3 OR v_st->'lines'->1->>'kind' <> 'facts'
     OR NOT (v_st->'lines' @> '[{"kind":"text","text":"Drei Monatsausgaben auf Tagesgeld."}]')
     OR NOT (v_st->'lines' @> '[{"kind":"expand","text":"Faustregel der Beratung."}]')
     OR NOT (v_st->'lines' @> '[{"key":"core.prompt.topic_enter_later","params":{"text":"Sparziel Notgroschen"}}]') THEN
    RAISE EXCEPTION 'FAIL [2 Karte 1]: %', v_st; END IF;
  SELECT card INTO v_st FROM agent.chat_prompts WHERE id = v_p2;
  IF v_st->'lines' @> '[{"kind":"facts"}]' OR NOT (v_st->'lines' @> '[{"key":"core.prompt.topic_open_point","params":{"text":"Betrag klären"}}]') THEN
    RAISE EXCEPTION 'FAIL [2 Karte 2]: %', v_st; END IF;
  IF (SELECT options FROM agent.chat_prompts WHERE id = v_p1) <> '[{"key":"accept","label_key":"core.prompt.button.accept"},{"key":"note","label_key":"core.prompt.button.note"}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [2 Knoepfe]'; END IF;
  RAISE NOTICE 'PASS [2 Karten]';

  -- ---------- 3) one_card, too_long, Ersetzen ----------
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
  IF (r->>'prompt_id')::bigint <> v_p1 THEN RAISE EXCEPTION 'FAIL [3 erste Karte offen]: %', r; END IF;
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','emergency_reserve','one_card',true,
         'topics', jsonb_build_array(jsonb_build_object('topic','A','content', repeat('a ', 1000)),
                                     jsonb_build_object('topic','B','content', repeat('b ', 1000)))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'too_long' THEN RAISE EXCEPTION 'FAIL [3 too_long]: %', r; END IF;
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','emergency_reserve','one_card',true,
         'more_in_part',true,
         'topics', jsonb_build_array(jsonb_build_object('topic','Notgroschen','content','Vier Monatsausgaben.'),
                                     jsonb_build_object('topic','Auffüllen','content','Erst auffüllen.'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'cards')::int <> 1 THEN RAISE EXCEPTION 'FAIL [3 one_card]: %', r; END IF;
  IF (SELECT string_agg(status, ',' ORDER BY id) FROM agent.chat_prompts WHERE id IN (v_p1, v_p2)) <> 'superseded,superseded' THEN
    RAISE EXCEPTION 'FAIL [3 alte Karten ersetzt]'; END IF;
  v_p1 := (r->'prompt_ids'->>0)::bigint;
  IF jsonb_array_length((SELECT payload->'topics' FROM agent.chat_prompts WHERE id = v_p1)) <> 2 THEN
    RAISE EXCEPTION 'FAIL [3 beide Themen in einer Zeile]'; END IF;
  RAISE NOTICE 'PASS [3 one_card + too_long + Ersetzen]';

  -- ---------- 4) Tipp speichert genau die Zeile ----------
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
  IF (r->>'prompt_id')::bigint <> v_p1 OR (r->>'send')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4 senden]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:accept', v_p1), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'continue' OR r->'continue'->>'agent' <> 'agent.pt_advisor'
     OR r->'continue'->>'as' <> 'task' OR r->'edit'->>'append' IS NULL OR position('same part' IN r->'continue'->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL [4 Tipp]: %', r; END IF;
  SELECT interview_state INTO v_st FROM agent.advisor_plans WHERE domain = '__pt__' AND status = 'draft';
  IF jsonb_array_length(v_st->'emergency_reserve'->'topics') <> 2
     OR v_st->'emergency_reserve'->'topics'->0->>'content' <> 'Vier Monatsausgaben.' THEN
    RAISE EXCEPTION 'FAIL [4 gespeichert]: %', v_st; END IF;
  RAISE NOTICE 'PASS [4 Tipp speichert]';

  -- ---------- 5) Stapel: then next, Speicher-Fehler ----------
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','goals_triggers',
         'topics', '[{"topic":"Haus","content":"Eigenkapital ansparen."},{"topic":"Auto","content":"Auto bar zahlen."}]'));
  v_p1 := (r->'prompt_ids'->>0)::bigint; v_p2 := (r->'prompt_ids'->>1)::bigint;
  IF (SELECT plan_id FROM agent.chat_prompts WHERE id = v_p1) IS NULL THEN RAISE EXCEPTION 'FAIL [5 plan_id am bestehenden Entwurf]'; END IF;
  PERFORM core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:accept', v_p1), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'next' THEN RAISE EXCEPTION 'FAIL [5 then next]: %', r; END IF;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
  IF (r->>'prompt_id')::bigint <> v_p2 THEN RAISE EXCEPTION 'FAIL [5 naechste Karte ohne Modell]: %', r; END IF;
  -- inzwischen ungueltig (Gesetz greift beim Tipp erneut): nichts gespeichert, Zeile ersetzt, Berater bekommt den Grund
  UPDATE agent.chat_prompts SET payload = jsonb_set(payload, '{topics,0,section_content}', '"Au中to bar"') WHERE id = v_p2;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:accept', v_p2), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'then' <> 'continue' OR r->'continue'->>'as' <> 'task' THEN
    RAISE EXCEPTION 'FAIL [5 Speicher-Fehler]: %', r; END IF;
  IF (SELECT status FROM agent.chat_prompts WHERE id = v_p2) <> 'superseded' THEN RAISE EXCEPTION 'FAIL [5 superseded]'; END IF;
  SELECT interview_state INTO v_st FROM agent.advisor_plans WHERE domain = '__pt__' AND status = 'draft';
  IF jsonb_array_length(v_st->'goals_triggers'->'topics') <> 1 THEN RAISE EXCEPTION 'FAIL [5 nichts zusaetzlich gespeichert]: %', v_st; END IF;
  RAISE NOTICE 'PASS [5 Stapel + Fehler]';
END $$;

-- ---------- 6) "geht noch nicht": deferred_entries mit Grund aus dem Katalog des Pakets (Sprache der Person) ----------
CREATE FUNCTION core.fn_t_pt_check(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE WHEN p->'payload'->>'t' = 'later' THEN '{"ok":true,"unsupported":true,"blocked_code":"tool_missing"}'::jsonb
              ELSE '{"ok":true}'::jsonb END $f$;
DO $$
DECLARE r jsonb;
BEGIN
  UPDATE core.advisors SET handoff_check_fn = 'core.fn_t_pt_check' WHERE domain = '__pt__';
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('core.handoff.blocked.tool_missing', 'de', 'Dafuer gibt es noch keinen Weg.', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','goals_triggers',
         'topics', jsonb_build_array(jsonb_build_object('topic','Rad','content','Ein Rad ansparen.',
            'handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','Rad eintragen'),
                                               jsonb_build_object('kind','other','payload',jsonb_build_object('t','later'),'text','Rad aus Einzahlungen'))))));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR r->'deferred_entries' IS DISTINCT FROM '[{"text":"Rad aus Einzahlungen","reason":"Dafuer gibt es noch keinen Weg."}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [6 deferred_entries]: %', r; END IF;
  r := agent.fn_advisor_propose_topics(jsonb_build_object('domain','__pt__','chat_id','111','section_key','goals_triggers',
         'topics', '[{"topic":"Rad","content":"Ein Rad ansparen."}]'));
  IF r->'deferred_entries' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [6 ohne]: %', r; END IF;
  RAISE NOTICE 'PASS [6 deferred_entries]';
END $$;

ROLLBACK;
