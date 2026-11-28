-- tests/db/core/test_chat_prompts.sql
-- Die offene Frage: agent.chat_prompts + core.prompt_kinds + Knopf-Prefix q.
--   * Gesetz: je Chat hoechstens eine Zeile open (Partial-UNIQUE);
--   * core.fn_create_choice_prompt: 2-3 Optionen je <= 24 Zeichen, keine Links/Dubletten, sonst invalid_choices; ersetzt eine
--     offene choice, eine offene andere Frage geht zurueck in die Schlange;
--   * core.fn_next_chat_prompt: Stapel in Reihenfolge, Zwischenantwort -> Frage neu senden (resend, alte message_id in
--     stale_message_ids), choice nach Textantwort -> superseded, Sweep erledigter Zeilen nach 30 Tagen, Pause eines Stapels
--     haelt bis zum naechsten Lauf desselben Beraters;
--   * core.fn_chat_prompt_sent, core.fn_open_chat_prompt, core.fn_advisor_pins.open_prompt_agent;
--   * core.fn_answer_chat_prompt (ueber core.fn_dispatch_callback): Privatchat, fremder Chat, veraltet, unbekannte Option,
--     note -> force_reply (Zeile bleibt offen), choice -> continue als Nachricht.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r      jsonb;
  v_c1   bigint;
  v_c2   bigint;
  v_t1   bigint;
  v_t2   bigint;
  v_b    uuid := gen_random_uuid();
  v_t0   timestamptz;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('q', 'core.fn_answer_chat_prompt', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || k, 'core'
  FROM unnest(ARRAY['core.toast.prompt_outdated','core.toast.prompt_not_yours','core.toast.prompt_private_only',
                    'core.prompt.note_ask','core.prompt.note_placeholder','core.prompt.button.note',
                    'core.prompt.button.accept','core.toast.prompt_card_open','core.toast.prompt_save_failed','core.prompt.facts_head']) k
  CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  DELETE FROM agent.chat_prompts;
  v_t0 := clock_timestamp() - interval '1 minute';

  -- ---------- 1) choice anlegen ----------
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','111','agent','agent.finance_advisor','options',
         jsonb_build_array('nur eine')));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'invalid_choices' THEN RAISE EXCEPTION 'FAIL [1 eine Option]: %', r; END IF;
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','111','agent','agent.finance_advisor','options',
         jsonb_build_array('a','b','c','d')));
  IF r->>'code' IS DISTINCT FROM 'invalid_choices' THEN RAISE EXCEPTION 'FAIL [1 vier Optionen]: %', r; END IF;
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','111','agent','agent.finance_advisor','options',
         jsonb_build_array('3 Monate', repeat('x', 25))));
  IF r->>'code' IS DISTINCT FROM 'invalid_choices' THEN RAISE EXCEPTION 'FAIL [1 zu lang]: %', r; END IF;
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','111','agent','agent.finance_advisor','options',
         jsonb_build_array('ja', 'https://x.test')));
  IF r->>'code' IS DISTINCT FROM 'invalid_choices' THEN RAISE EXCEPTION 'FAIL [1 Link]: %', r; END IF;
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','111','agent','agent.finance_advisor','options',
         jsonb_build_array('Ja', 'ja')));
  IF r->>'code' IS DISTINCT FROM 'invalid_choices' THEN RAISE EXCEPTION 'FAIL [1 Dublette]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.chat_prompts) THEN RAISE EXCEPTION 'FAIL [1 Ablehnung schrieb]'; END IF;
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','111','agent','agent.finance_advisor','options',
         '["3 Monate (empfohlen)","6 Monate","Anders"]'));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'buttons') < 1 THEN RAISE EXCEPTION 'FAIL [1 ok]: %', r; END IF;
  v_c1 := (r->>'prompt_id')::bigint;
  IF r->'buttons'->0->0->>'data' IS DISTINCT FROM format('q:%s:o1', v_c1) OR r->'buttons'->0->0->>'text' <> '3 Monate (empfohlen)' THEN
    RAISE EXCEPTION 'FAIL [1 Knopf-Daten]: %', r; END IF;
  IF (SELECT status FROM agent.chat_prompts WHERE id = v_c1) <> 'open' THEN RAISE EXCEPTION 'FAIL [1 choice ist offen]'; END IF;
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','999','agent','agent.finance_advisor','options','["a","b"]'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 unbekannter Chat]: %', r; END IF;
  RAISE NOTICE 'PASS [1 choice anlegen]';

  -- ---------- 2) Gesetz: hoechstens eine offene Zeile je Chat ----------
  BEGIN
    INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, status, options)
    VALUES ('111', 'erika', 'agent.finance_advisor', 'choice', 'open', '[{"key":"o1","label":"x"}]');
    RAISE EXCEPTION 'FAIL [2 zweite offene Zeile angenommen]';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS [2 eine offene Zeile]';

  -- ---------- 3) Senden, offen lassen, Zwischenantwort ----------
  r := core.fn_chat_prompt_sent(jsonb_build_object('prompt_id', v_c1, 'message_id', 5001));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 sent]: %', r; END IF;
  UPDATE agent.chat_prompts SET sent_at = v_t0 - interval '1 minute' WHERE id = v_c1;
  r := core.fn_open_chat_prompt('111');
  IF (r->>'id')::bigint IS DISTINCT FROM v_c1 OR r->>'kind' <> 'choice' OR r->>'agent' <> 'agent.finance_advisor' THEN
    RAISE EXCEPTION 'FAIL [3 fn_open_chat_prompt]: %', r; END IF;
  r := core.fn_advisor_pins(jsonb_build_object('person_id','erika','role','owner','chat_id','111'));
  IF r->>'open_prompt_agent' IS DISTINCT FROM 'agent.finance_advisor' THEN RAISE EXCEPTION 'FAIL [3 pins]: %', r; END IF;
  r := core.fn_advisor_pins(jsonb_build_object('person_id','erika','role','owner'));
  IF NOT (r ? 'open_prompt_agent') OR r->>'open_prompt_agent' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 pins ohne chat]: %', r; END IF;
  -- liegengebliebene Frage (aelter als 2 Stunden) kapert das Routing nicht
  UPDATE agent.chat_prompts SET sent_at = now() - interval '3 hours' WHERE id = v_c1;
  r := core.fn_advisor_pins(jsonb_build_object('person_id','erika','role','owner','chat_id','111'));
  IF r->>'open_prompt_agent' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 pins alte Frage]: %', r; END IF;
  UPDATE agent.chat_prompts SET sent_at = v_t0 - interval '1 minute' WHERE id = v_c1;
  -- Lauf ohne eigenen Text: offene Frage bleibt, nichts zu senden
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', v_t0,'replied', false));
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 nichts senden]: %', r; END IF;
  -- Text war die Antwort auf die choice -> superseded, Knoepfe der alten Nachricht entfernen
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', v_t0,'replied', true));
  IF (r->>'send')::boolean IS NOT FALSE OR r->'stale_message_ids' <> '[5001]'::jsonb THEN RAISE EXCEPTION 'FAIL [3 choice superseded]: %', r; END IF;
  IF (SELECT status FROM agent.chat_prompts WHERE id = v_c1) <> 'superseded' THEN RAISE EXCEPTION 'FAIL [3 status]'; END IF;
  RAISE NOTICE 'PASS [3 choice nach Textantwort]';

  -- ---------- 4) Stapel in Reihenfolge, Resend nach Zwischenantwort ----------
  v_t0 := clock_timestamp();   -- neuer Lauf: die in 3 ersetzte choice gehoert zu einem frueheren Lauf
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, batch_id, ord, status, card, options, payload)
  VALUES ('111','erika','agent.finance_advisor','hint', v_b, 2, 'queued',
          '{"lines":[{"kind":"text","text":"Zweite"}]}', '[{"key":"now","label":"B"}]', '{"label":"zweite"}'),
         ('111','erika','agent.finance_advisor','hint', v_b, 1, 'queued',
          '{"lines":[{"kind":"head","text":"Kopf"},{"kind":"text","text":"Erste"}]}',
          '[{"key":"now","label":"A"},{"key":"note","label_key":"core.prompt.button.note"}]', '{"label":"erste"}');
  SELECT id INTO v_t1 FROM agent.chat_prompts WHERE batch_id = v_b AND ord = 1;
  SELECT id INTO v_t2 FROM agent.chat_prompts WHERE batch_id = v_b AND ord = 2;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', v_t0,'replied', false));
  IF (r->>'send')::boolean IS NOT TRUE OR (r->>'prompt_id')::bigint <> v_t1 OR (r->>'resend')::boolean IS NOT FALSE
     OR r->>'kind' <> 'hint' OR r->'card'->'lines'->0->>'kind' <> 'head' OR r->'card'->'lines'->1->>'text' <> 'Erste'
     OR r->'buttons'->0->1->>'text' <> 'DE:core.prompt.button.note' OR r->'buttons'->0->1->>'data' <> format('q:%s:note', v_t1) THEN
    RAISE EXCEPTION 'FAIL [4 erste Zeile]: %', r; END IF;
  IF (SELECT status FROM agent.chat_prompts WHERE id = v_t1) <> 'open' OR (SELECT status FROM agent.chat_prompts WHERE id = v_t2) <> 'queued' THEN
    RAISE EXCEPTION 'FAIL [4 Status nach Senden]'; END IF;
  PERFORM core.fn_chat_prompt_sent(jsonb_build_object('prompt_id', v_t1, 'message_id', 5002));
  UPDATE agent.chat_prompts SET sent_at = v_t0 - interval '1 minute' WHERE id = v_t1;
  -- Zwischenantwort des Bots in einem spaeteren Lauf -> dieselbe Frage neu unten senden
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', v_t0,'replied', true));
  IF (r->>'send')::boolean IS NOT TRUE OR (r->>'prompt_id')::bigint <> v_t1 OR (r->>'resend')::boolean IS NOT TRUE
     OR r->'stale_message_ids' <> '[5002]'::jsonb OR r->'stale'->0->>'message_id' <> '5002'
     OR r->'stale'->0->'card'->'lines'->1->>'text' <> 'Erste' THEN
    RAISE EXCEPTION 'FAIL [4 resend]: %', r; END IF;
  PERFORM core.fn_chat_prompt_sent(jsonb_build_object('prompt_id', v_t1, 'message_id', 5003));
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', v_t0,'replied', true));
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4 in diesem Lauf gesendet -> nichts]: %', r; END IF;
  RAISE NOTICE 'PASS [4 Stapel + resend]';

  -- ---------- 5) Tipp ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:now', v_t1), 'chat_id','111','chat_type','group'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'not_private_chat' OR r->>'toast' <> 'DE:core.toast.prompt_private_only' THEN
    RAISE EXCEPTION 'FAIL [5 Gruppe]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:now', v_t1), 'chat_id','222','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'not_yours' OR r->>'toast' <> 'EN:core.toast.prompt_not_yours' THEN
    RAISE EXCEPTION 'FAIL [5 fremder Chat]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:zz', v_t1), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'unknown_option' THEN RAISE EXCEPTION 'FAIL [5 Option]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'q:999999999:now', 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'unknown_prompt' OR (r->'edit'->>'keep_text')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [5 unbekannt]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:note', v_t1), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'force_reply'->>'text' <> 'DE:core.prompt.note_ask'
     OR r->'force_reply'->>'placeholder' <> 'DE:core.prompt.note_placeholder' OR r->>'then' <> 'none' OR r ? 'edit' THEN
    RAISE EXCEPTION 'FAIL [5 note]: %', r; END IF;
  IF (SELECT status FROM agent.chat_prompts WHERE id = v_t1) <> 'open' THEN RAISE EXCEPTION 'FAIL [5 note laesst offen]'; END IF;
  -- choice verdraengt die offene Frage in die Schlange; ihr Tipp laeuft weiter wie eine Nachricht
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','111','agent','agent.finance_advisor','options','["3 Monate","6 Monate"]'));
  v_c2 := (r->>'prompt_id')::bigint;
  IF (SELECT status FROM agent.chat_prompts WHERE id = v_t1) <> 'queued' THEN RAISE EXCEPTION 'FAIL [5 zurueck in die Schlange]'; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:o2', v_c2), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'continue' OR r->'continue'->>'agent' <> 'agent.finance_advisor'
     OR r->'continue'->>'text' <> '6 Monate' OR r->'continue'->>'as' <> 'message'
     OR (r->'edit'->>'keep_text')::boolean IS NOT TRUE OR r->'edit'->>'append' <> '→ 6 Monate' THEN
    RAISE EXCEPTION 'FAIL [5 choice]: %', r; END IF;
  IF (SELECT status || '/' || answer_key FROM agent.chat_prompts WHERE id = v_c2) <> 'answered/o2'
     OR (SELECT decided_at FROM agent.chat_prompts WHERE id = v_c2) IS NULL THEN RAISE EXCEPTION 'FAIL [5 answered]'; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:o1', v_c2), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'outdated' OR r->>'toast' <> 'DE:core.toast.prompt_outdated'
     OR (r->'edit'->>'keep_text')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [5 Doppeltipp]: %', r; END IF;
  RAISE NOTICE 'PASS [5 Tipp]';

  -- ---------- 6) Sweep ----------
  UPDATE agent.chat_prompts SET decided_at = now() - interval '31 days' WHERE id = v_c2;
  PERFORM core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', now(),'replied', false));
  IF EXISTS (SELECT 1 FROM agent.chat_prompts WHERE id = v_c2) OR NOT EXISTS (SELECT 1 FROM agent.chat_prompts WHERE id = v_c1) THEN
    RAISE EXCEPTION 'FAIL [6 Sweep nur nach 30 Tagen]'; END IF;
  RAISE NOTICE 'PASS [6 Sweep]';
  -- ---------- 7) Test-Sentinel der Agent-Suiten ('test_…' = Owner), sonst nur Telegram-Zahlen ----------
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','test_ac05','agent','agent.finance_advisor','options','["Ja","Nein"]'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT person_id FROM agent.chat_prompts WHERE id = (r->>'prompt_id')::bigint) <> 'erika' THEN
    RAISE EXCEPTION 'FAIL [7 Test-Sentinel]: %', r; END IF;
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','abc','agent','agent.finance_advisor','options','["Ja","Nein"]'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 freie chat_id]: %', r; END IF;
  BEGIN
    INSERT INTO agent.chat_prompts (chat_id, agent, kind) VALUES ('test 1', 'agent.finance_advisor', 'choice');
    RAISE EXCEPTION 'FAIL [7 CHECK chat_id]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  IF core.fn_chat_person('test_e2e_finance')->>'person_id' <> 'erika' OR (core.fn_chat_person('999')->>'found')::boolean THEN
    RAISE EXCEPTION 'FAIL [7 fn_chat_person]'; END IF;
  RAISE NOTICE 'PASS [7 Test-Sentinel]';

  -- ---------- 8) choice, deren Senden nie bestaetigt wurde, blockiert die Schlange nicht ----------
  DELETE FROM agent.chat_prompts WHERE chat_id = '222';
  r := core.fn_create_choice_prompt(jsonb_build_object('chat_id','222','agent','agent.finance_advisor','options','["Ja","Nein"]'));
  v_c2 := (r->>'prompt_id')::bigint;
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, status, card, options, payload)
  VALUES ('222','lena','agent.finance_advisor','hint','queued', '{"lines":[{"kind":"text","text":"Wartet"}]}',
          '[{"key":"now","label":"A"}]', '{"label":"wartet"}')
  RETURNING id INTO v_t2;
  -- im Lauf, der sie angelegt hat (Laufbeginn vor dem Anlegen): sie haengt an der Antwort, die gerade gesendet wird
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','222','run_started_at', now() - interval '1 minute','replied', true));
  IF (r->>'send')::boolean IS NOT FALSE OR (SELECT status FROM agent.chat_prompts WHERE id = v_c2) <> 'open' THEN
    RAISE EXCEPTION 'FAIL [8 selber Lauf]: %', r; END IF;
  -- ein Lauf kurz danach (der Send des ersten kann noch haengen): bleibt stehen
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','222','run_started_at', now() + interval '9 minutes','replied', true));
  IF (r->>'send')::boolean IS NOT FALSE OR (SELECT status FROM agent.chat_prompts WHERE id = v_c2) <> 'open' THEN
    RAISE EXCEPTION 'FAIL [8 kurz danach]: %', r; END IF;
  -- ein spaeterer Lauf: die Knoepfe hat niemand gesehen -> ersetzt, die wartende Frage kommt
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','222','run_started_at', now() + interval '11 minutes','replied', false));
  IF (SELECT status FROM agent.chat_prompts WHERE id = v_c2) <> 'superseded'
     OR (r->>'send')::boolean IS NOT TRUE OR (r->>'prompt_id')::bigint IS DISTINCT FROM v_t2 THEN
    RAISE EXCEPTION 'FAIL [8 spaeterer Lauf]: %', r; END IF;
  RAISE NOTICE 'PASS [8 nie gesendete choice]';
END $$;

-- 9) Pause in der Schlussprüfung haelt: ein Stapel, dessen Uebersicht mit pause beantwortet wurde, kommt nicht beim Lauf
--    eines anderen Agenten (oder ohne Angabe), erst nach einem spaeteren Lauf desselben Beraters (agent); ein neuer
--    Pruef-Durchgang (neuer Stapel) geht vor.
DO $$
DECLARE
  r jsonb; v_b uuid := gen_random_uuid(); v_b2 uuid := gen_random_uuid(); v_ov bigint; v_p1 bigint; v_ov2 bigint;
BEGIN
  DELETE FROM agent.chat_prompts WHERE chat_id = '111';
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, batch_id, ord, status, answer_key, decided_at, sent_at, card, options, payload)
  VALUES ('111', 'erika', 'agent.finance_advisor', 'finding', v_b, 0, 'answered', 'pause', clock_timestamp() - interval '5 minutes',
          clock_timestamp() - interval '6 minutes', '{"lines":[{"kind":"text","text":"Uebersicht"}]}',
          '[{"key":"go","label":"Los"},{"key":"pause","label":"Pause"}]', '{"role":"overview","points":1,"label":"check"}')
  RETURNING id INTO v_ov;
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, batch_id, ord, status, card, options, payload)
  VALUES ('111', 'erika', 'agent.finance_advisor', 'finding', v_b, 1, 'queued', '{"lines":[{"kind":"text","text":"Punkt 1"}]}',
          '[{"key":"keep","label":"Passt"}]', '{"label":"punkt 1"}')
  RETURNING id INTO v_p1;

  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', clock_timestamp(),'replied', true));
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [9 ohne agent gesendet]: %', r; END IF;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', clock_timestamp(),'replied', true,
         'agent', 'agent.finance'));
  IF (r->>'send')::boolean IS NOT FALSE OR (SELECT status FROM agent.chat_prompts WHERE id = v_p1) <> 'queued' THEN
    RAISE EXCEPTION 'FAIL [9 anderer Agent gesendet]: %', r; END IF;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', clock_timestamp(),'replied', true,
         'agent', 'agent.finance_advisor'));
  IF (r->>'send')::boolean IS NOT TRUE OR (r->>'prompt_id')::bigint IS DISTINCT FROM v_p1 THEN
    RAISE EXCEPTION 'FAIL [9 Berater-Lauf gibt nicht frei]: %', r; END IF;

  -- neuer Durchgang waehrend einer Pause: sein Stapel kommt, der pausierte bleibt liegen
  DELETE FROM agent.chat_prompts WHERE chat_id = '111';
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, batch_id, ord, status, answer_key, decided_at, sent_at, card, options, payload)
  VALUES ('111', 'erika', 'agent.finance_advisor', 'finding', v_b, 0, 'answered', 'pause', clock_timestamp() - interval '5 minutes',
          clock_timestamp() - interval '6 minutes', '{"lines":[{"kind":"text","text":"Uebersicht"}]}',
          '[{"key":"go","label":"Los"}]', '{"role":"overview","points":1,"label":"check"}');
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, batch_id, ord, status, card, options, payload)
  VALUES ('111', 'erika', 'agent.finance_advisor', 'finding', v_b, 1, 'queued', '{"lines":[{"kind":"text","text":"Punkt 1"}]}',
          '[{"key":"keep","label":"Passt"}]', '{"label":"punkt 1"}');
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, batch_id, ord, status, card, options, payload)
  VALUES ('111', 'erika', 'agent.finance_advisor', 'finding', v_b2, 0, 'queued', '{"lines":[{"kind":"text","text":"Neue Uebersicht"}]}',
          '[{"key":"go","label":"Los"}]', '{"role":"overview","points":0,"label":"check 2"}')
  RETURNING id INTO v_ov2;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','run_started_at', clock_timestamp(),'replied', true));
  IF (r->>'prompt_id')::bigint IS DISTINCT FROM v_ov2 THEN RAISE EXCEPTION 'FAIL [9 neuer Durchgang]: %', r; END IF;
  RAISE NOTICE 'PASS [9 Pause haelt bis zum naechsten Lauf des Beraters]';
END $$;

ROLLBACK;
