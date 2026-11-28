-- tests/db/core/test_fn_record_handoff_correction.sql
-- agent.fn_record_handoff_correction(p): Ergebnis des Auftrags "Eintrag pruefen" - eine abgeschlossene Vormerkung bekommt
-- eine NEUE Vormerkung mit follows_task_id (die alte bleibt unveraendert), Abschnitt und Thema der alten:
--   * nur Altbestand der Person des Absenders (done ohne close_reason), Schreibrecht des Plans, hoechstens eine Folge-Aufgabe;
--   * Vorpruefung (handoff_check_fn, mode agree): Aufruf -> wanted, status open; "geht noch nicht" -> deferred mit
--     blocked_code; mehrdeutig/Wahl -> {ok:false} mit Kandidaten bzw. Optionen im reason, ohne Write; option waehlt;
--   * why <= 160, text 1-300; Kartenzeilen handoff_note + handoff_why.
BEGIN;

CREATE FUNCTION core.fn_t_corr_check(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  CASE p->'payload'->>'t'
    WHEN 'unsupported' THEN RETURN '{"ok":true,"unsupported":true,"blocked_code":"tool_missing","call":{"tool":"set_x","input":{"a":2}}}'::jsonb;
    WHEN 'badflag' THEN RETURN '{"ok":false,"code":"handoff_choice_needed","reason":"pick.","options":[{"key":"x","label_key":"core.t.five","recommended":"yes"}]}'::jsonb;
    WHEN 'ambiguous' THEN RETURN '{"ok":false,"code":"handoff_ref_ambiguous","reason":"two match.","candidates":[{"id":1,"label":"Konto A"},{"id":2,"label":"Konto B"}]}'::jsonb;
    WHEN 'choice' THEN
      IF p->>'option' = 'four' THEN RETURN '{"ok":true,"calls":[{"tool":"set_x","input":{"n":4}}]}'::jsonb; END IF;
      RETURN '{"ok":false,"code":"handoff_choice_needed","reason":"pick one.","options":[{"key":"four","label_key":"core.t.four","reason_key":"core.t.four_why","params":{"n":4},"recommended":true},{"key":"five","label_key":"core.t.five","recommended":false}]}'::jsonb;
    ELSE RETURN jsonb_build_object('ok', true, 'call', jsonb_build_object('tool', 'set_x', 'input', p->'payload'));
  END CASE;
END $f$;

DO $$
DECLARE
  d CONSTANT text := '__corr__';
  r jsonb;
  v_old int;
  v_open int;
  v_n int;
  t agent.handoff_tasks%ROWTYPE;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step, handoff_check_fn)
  VALUES (d, 'core', '__corr___planning', 'core.fn_x', TRUE, 'core.fn_t_corr_check');
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.handoff.blocked.tool_missing', 'de', 'Dafuer gibt es noch keinen Weg.', 'core'),
    ('core.t.four', 'de', '{n} Raten', 'core'), ('core.t.four_why', 'de', 'passt genau', 'core'), ('core.t.five', 'de', 'fuenf Raten', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, payload, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'Konten', 'recurring_payment', '{"amount":50}', 'Rate 50 eintragen', 'done', now()) RETURNING id INTO v_old;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES (d, 'core', 'erika', 's', 'other', 'noch offen') RETURNING id INTO v_open;

  -- 1) Ablehnungen ohne Write
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','222','handoff_task_id',v_old,'kind','other','text','x'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 fremde Person]: %', r; END IF;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_open,'kind','other','text','x'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_not_closed' THEN RAISE EXCEPTION 'FAIL [1 offen]: %', r; END IF;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',999999,'kind','other','text','x'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 unbekannt]: %', r; END IF;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','other','text','x','why',repeat('w',161)));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_why_too_long' THEN RAISE EXCEPTION 'FAIL [1 why]: %', r; END IF;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','other','text','  '));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_text_invalid' THEN RAISE EXCEPTION 'FAIL [1 text]: %', r; END IF;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','gibtsnicht','text','x'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_kind_invalid' THEN RAISE EXCEPTION 'FAIL [1 kind]: %', r; END IF;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','recurring_payment',
         'payload',jsonb_build_object('t','ambiguous'),'text','Rate vom Konto'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_ref_ambiguous' OR strpos(r->>'reason', 'Candidates: Konto A | Konto B') = 0 THEN
    RAISE EXCEPTION 'FAIL [1 mehrdeutig]: %', r; END IF;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','recurring_payment',
         'payload',jsonb_build_object('t','choice'),'text','Raten'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_choice_needed'
     OR strpos(r->>'reason', 'option=four (recommended): 4 Raten (passt genau); option=five: fuenf Raten') = 0 THEN
    RAISE EXCEPTION 'FAIL [1 Wahl]: %', r; END IF;
  -- eine kaputte Empfehlungs-Markierung der Paket-fn bricht die Ablehnung nicht
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','recurring_payment',
         'payload',jsonb_build_object('t','badflag'),'text','Raten'));
  IF r->>'code' IS DISTINCT FROM 'handoff_choice_needed' OR strpos(r->>'reason', 'option=x: fuenf Raten') = 0 THEN RAISE EXCEPTION 'FAIL [1 Markierung]: %', r; END IF;
  -- nur Altbestand (erledigt, ohne close_reason): mit Werkzeug abgeschlossen, schon im System oder gestrichen -> abgelehnt
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at, close_reason)
  VALUES (d, 'core', 'erika', 's', 'other', 'eingetragen', 'done', now(), 'entered') RETURNING id INTO v_n;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_n,'kind','other','text','x'));
  IF r->>'code' IS DISTINCT FROM 'handoff_task_not_legacy' THEN RAISE EXCEPTION 'FAIL [1 entered]: %', r; END IF;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at, close_reason)
  VALUES (d, 'core', 'erika', 's', 'other', 'gestrichen', 'cancelled', now(), 'dropped') RETURNING id INTO v_n;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_n,'kind','other','text','x'));
  IF r->>'code' IS DISTINCT FROM 'handoff_task_not_legacy' THEN RAISE EXCEPTION 'FAIL [1 dropped]: %', r; END IF;
  -- Schreibrecht des Plans (Haushaltsplan: owner_only): ein Mitglied mit eigenem Altbestand -> abgelehnt
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'lena', 's', 'other', 'alt lena', 'done', now()) RETURNING id INTO v_n;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','222','handoff_task_id',v_n,'kind','other','text','x'));
  IF r->>'code' IS DISTINCT FROM 'handoff_not_permitted' THEN RAISE EXCEPTION 'FAIL [1 Mitglied]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE follows_task_id IS NOT NULL) THEN RAISE EXCEPTION 'FAIL [1 trotzdem geschrieben]'; END IF;

  -- 2) Aufruf -> neue offene Vormerkung mit Verweis, Abschnitt/Thema der alten; die alte bleibt unveraendert
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old::text,'kind','recurring_payment',
         'payload',jsonb_build_object('amount',60),'text','Rate auf 60 aendern','why','Die Rate wurde im Plan auf 60 erhoeht.'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'open' OR r->>'blocked_code' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 ok]: %', r; END IF;
  SELECT * INTO t FROM agent.handoff_tasks WHERE id = (r->>'task_id')::int;
  IF t.follows_task_id <> v_old OR t.status <> 'open' OR t.section_key <> 's' OR t.topic <> 'Konten' OR t.person_id <> 'erika'
     OR t.wanted <> '{"tool":"set_x","input":{"amount":60}}'::jsonb OR t.why <> 'Die Rate wurde im Plan auf 60 erhoeht.' OR t.claimed_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2 Zeile]: %', row_to_json(t); END IF;
  IF r->'card_lines'->0->>'value' <> 'core.hitl.handoff_note' OR r->'card_lines'->0->'params'->>'text' <> 'Rate auf 60 aendern'
     OR r->'card_lines'->1->>'value' <> 'core.hitl.handoff_why' THEN RAISE EXCEPTION 'FAIL [2 Karte]: %', r; END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_old) <> 'done' THEN RAISE EXCEPTION 'FAIL [2 alte veraendert]'; END IF;
  -- hoechstens eine Folge-Aufgabe
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','other','text','nochmal'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_followed' THEN RAISE EXCEPTION 'FAIL [2 zweimal]: %', r; END IF;

  -- 3) "geht noch nicht" -> deferred mit Code, Aufruf trotzdem als wanted
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'other', 'alt 3', 'done', now()) RETURNING id INTO v_open;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_open,'kind','recurring_payment',
         'payload',jsonb_build_object('t','unsupported'),'text','Rate bis Betrag'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'deferred' OR r->>'blocked_code' <> 'tool_missing'
     OR r->'card_lines'->0->>'value' <> 'core.hitl.handoff_planned_deferred' THEN RAISE EXCEPTION 'FAIL [3 deferred]: %', r; END IF;
  IF (SELECT wanted FROM agent.handoff_tasks WHERE id = (r->>'task_id')::int) <> '{"tool":"set_x","input":{"a":2}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3 wanted]'; END IF;

  -- 4) Wahl per option
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'other', 'alt 2', 'done', now()) RETURNING id INTO v_old;
  r := agent.fn_record_handoff_correction(jsonb_build_object('chat_id','111','handoff_task_id',v_old,'kind','recurring_payment',
         'payload',jsonb_build_object('t','choice'),'option','four','text','Vier Raten'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT wanted FROM agent.handoff_tasks WHERE id = (r->>'task_id')::int) <> '[{"tool":"set_x","input":{"n":4}}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4 option]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_record_handoff_correction';
END $$;
ROLLBACK;
