-- tests/db/core/test_fn_advisor_record_check_findings.sql
-- Schlusspruefung als DB-gefuehrter Stapel:
--   * agent.fn_advisor_record_check_findings: kein Entwurf -> no_draft; Zitat nicht woertlich im genannten Thema ->
--     quote_not_found; Vorschlag im Probelauf abgelehnt -> proposal_rejected; nichts angelegt;
--   * DB ergaenzt offene Punkte (open_point) und fehlende Teile (missing_part); Reihenfolge contradiction -> missing ->
--     missing_part -> open_point hinter einer Uebersichts-Zeile; hoechstens advisor.check_max_passes Durchgaenge;
--   * agent.fn_prompt_answer_finding: Uebersicht go -> next; accept speichert den Vorschlag (changed), keep laesst bewusst
--     so; nach dem letzten Punkt zweiter Durchgang nur bei Aenderung, danach Auftrag "veroeffentlichen";
--   * agent.fn_advisor_publish_plan liest Funde (je Text der juengste Ausgang) und Durchgaenge aus den Zeilen, der Modell-
--     Eingang zaehlt dann nicht; offene Zeile -> final_check_open.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r      jsonb;
  v_ov   bigint;
  v_f1   bigint;
  v_n    int;
  v_plan int;
  v_st   jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM core.advisors WHERE domain = '__ck__';
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, stages) VALUES
    ('__ck__', '__ck___planning', 'finance.fn_advisor_review', 'agent.ck_advisor', 'core',
     '[{"key":"all","sections":["debts_loans","emergency_reserve","goals_triggers"]}]');
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('q', 'core.fn_answer_chat_prompt', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;
  DELETE FROM agent.advisor_plans WHERE domain = '__ck__';
  DELETE FROM agent.chat_prompts;

  r := agent.fn_advisor_record_check_findings(jsonb_build_object('domain','__ck__','chat_id','111','findings','[]'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'no_draft' THEN RAISE EXCEPTION 'FAIL [0 no_draft]: %', r; END IF;

  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__ck__','chat_id','111','section_key','debts_loans',
         'topic','Autokredit','section_content','Der Autokredit wird am Ende aus dem Tagesgeld bezahlt.'));
  v_plan := (r->>'plan_id')::int;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__ck__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','Das Tagesgeld ist nur für Notfälle.','open_points','["Konto wählen"]'));

  -- ---------- 1) Ablehnungen ----------
  r := agent.fn_advisor_record_check_findings(jsonb_build_object('domain','__ck__','chat_id','111','findings', jsonb_build_array(
         jsonb_build_object('category','contradiction','ref_a', jsonb_build_object('section_key','debts_loans','topic','Autokredit'),
           'quote_a','aus dem Girokonto bezahlt','ref_b', jsonb_build_object('section_key','emergency_reserve','topic','Notgroschen'),
           'quote_b','nur für Notfälle','question','Woher kommt das Geld?'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'quote_not_found' OR (r->>'index')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [1 quote_not_found]: %', r; END IF;
  r := agent.fn_advisor_record_check_findings(jsonb_build_object('domain','__ck__','chat_id','111','findings', jsonb_build_array(
         jsonb_build_object('category','contradiction','ref_a', jsonb_build_object('section_key','debts_loans','topic','Autokredit'),
           'quote_a','aus dem Tagesgeld bezahlt','ref_b', jsonb_build_object('section_key','emergency_reserve','topic','Notgroschen'),
           'quote_b','nur für Notfälle','proposal', jsonb_build_object('section_key','debts_loans','topic','Autokredit',
               'content','Der Autokredit wird aus einem eigenen Sparziel be비zahlt.')))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'proposal_rejected' THEN RAISE EXCEPTION 'FAIL [1 proposal_rejected]: %', r; END IF;
  r := agent.fn_advisor_record_check_findings(jsonb_build_object('domain','__ck__','chat_id','111','findings', jsonb_build_array(
         jsonb_build_object('category','contradiction','ref_a', jsonb_build_object('section_key','debts_loans','topic','Autokredit'),
           'quote_a','aus dem Tagesgeld bezahlt'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'invalid_finding' THEN RAISE EXCEPTION 'FAIL [1 ohne Vorschlag/Frage]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.chat_prompts) THEN RAISE EXCEPTION 'FAIL [1 Ablehnung schrieb]'; END IF;
  RAISE NOTICE 'PASS [1 Ablehnungen]';

  -- ---------- 2) Stapel mit DB-eigenen Punkten ----------
  r := agent.fn_advisor_record_check_findings(jsonb_build_object('domain','__ck__','chat_id','111','findings', jsonb_build_array(
         jsonb_build_object('category','missing','ref_a', jsonb_build_object('section_key','emergency_reserve','topic','Notgroschen'),
           'quote_a','Das Tagesgeld','question','Bis wann soll der Notgroschen voll sein?'),
         jsonb_build_object('category','contradiction','ref_a', jsonb_build_object('section_key','debts_loans','topic','Autokredit'),
           'quote_a','aus dem Tagesgeld bezahlt','ref_b', jsonb_build_object('section_key','emergency_reserve','topic','Notgroschen'),
           'quote_b','nur für Notfälle','proposal', jsonb_build_object('section_key','debts_loans','topic','Autokredit',
               'content','Der Autokredit wird aus einem eigenen Sparziel bezahlt.')))));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'pass')::int <> 1 OR (r->>'last_pass')::boolean
     OR (r->'counts'->>'contradiction')::int <> 1 OR (r->'counts'->>'missing')::int <> 1
     OR (r->'counts'->>'open_point')::int <> 1 OR (r->'counts'->>'missing_part')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [2 ok]: %', r; END IF;
  IF (SELECT string_agg(COALESCE(payload->>'category', payload->>'role'), ',' ORDER BY ord) FROM agent.chat_prompts WHERE status = 'queued')
     <> 'overview,contradiction,missing,missing_part,open_point' THEN
    RAISE EXCEPTION 'FAIL [2 Reihenfolge]: %', (SELECT string_agg(COALESCE(payload->>'category', payload->>'role'), ',' ORDER BY ord) FROM agent.chat_prompts); END IF;
  IF (SELECT count(*) FROM agent.chat_prompts WHERE plan_id = v_plan AND kind = 'finding' AND agent = 'agent.ck_advisor') <> 5 THEN
    RAISE EXCEPTION 'FAIL [2 plan_id/agent]'; END IF;
  SELECT id INTO v_ov FROM agent.chat_prompts WHERE payload->>'role' = 'overview';
  SELECT id INTO v_f1 FROM agent.chat_prompts WHERE payload->>'category' = 'contradiction';
  IF (SELECT options FROM agent.chat_prompts WHERE id = v_f1) @> '[{"key":"accept"}]' IS NOT TRUE
     OR (SELECT options FROM agent.chat_prompts WHERE payload->>'category' = 'missing') @> '[{"key":"accept"}]' THEN
    RAISE EXCEPTION 'FAIL [2 Knoepfe je Art]'; END IF;
  RAISE NOTICE 'PASS [2 Stapel]';

  -- ---------- 3) Publish vor Abschluss -> final_check_open ----------
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__ck__','chat_id','111','plan_md','# Plan'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'final_check_open' THEN RAISE EXCEPTION 'FAIL [3 final_check_open]: %', r; END IF;
  RAISE NOTICE 'PASS [3 Publish wartet]';

  -- ---------- 4) Tippen: Uebersicht, accept, keep ----------
  PERFORM core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:go', v_ov), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'next' THEN RAISE EXCEPTION 'FAIL [4 Uebersicht]: %', r; END IF;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
  IF (r->>'prompt_id')::bigint <> v_f1 THEN RAISE EXCEPTION 'FAIL [4 erster Punkt]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:accept', v_f1), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'next' THEN RAISE EXCEPTION 'FAIL [4 accept]: %', r; END IF;
  SELECT interview_state INTO v_st FROM agent.advisor_plans WHERE id = v_plan;
  IF v_st->'debts_loans'->'topics'->0->>'content' <> 'Der Autokredit wird aus einem eigenen Sparziel bezahlt.' THEN
    RAISE EXCEPTION 'FAIL [4 Vorschlag gespeichert]: %', v_st; END IF;
  IF (SELECT payload->>'outcome' || '/' || (payload->>'changed') FROM agent.chat_prompts WHERE id = v_f1) <> 'resolved/true' THEN
    RAISE EXCEPTION 'FAIL [4 outcome]'; END IF;
  -- die uebrigen drei Punkte so lassen; nach dem letzten -> zweiter Durchgang (ein Punkt hat Themen geaendert)
  FOR v_n IN 1..3 LOOP
    r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
    r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:keep', r->>'prompt_id'), 'chat_id','111','chat_type','private'));
  END LOOP;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'continue' OR r->'continue'->>'as' <> 'task'
     OR r->'continue'->>'agent' <> 'agent.ck_advisor' OR position('second' IN r->'continue'->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL [4 zweiter Durchgang]: %', r; END IF;
  IF (SELECT payload->>'outcome' FROM agent.chat_prompts WHERE payload->>'category' = 'open_point') <> 'deferred'
     OR (SELECT payload->>'outcome' FROM agent.chat_prompts WHERE payload->>'category' = 'missing') <> 'accepted' THEN
    RAISE EXCEPTION 'FAIL [4 keep-outcomes]'; END IF;
  RAISE NOTICE 'PASS [4 Tippen]';

  -- ---------- 5) letzter Durchgang, Grenze, Publish liest die Zeilen ----------
  r := agent.fn_advisor_record_check_findings(jsonb_build_object('domain','__ck__','chat_id','111','findings','[]'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'pass')::int <> 2 OR (r->>'last_pass')::boolean IS NOT TRUE
     OR (r->'counts'->>'open_point')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [5 zweiter Durchgang]: %', r; END IF;
  r := agent.fn_advisor_record_check_findings(jsonb_build_object('domain','__ck__','chat_id','111','findings','[]'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'check_passes_exhausted' THEN RAISE EXCEPTION 'FAIL [5 Grenze]: %', r; END IF;
  PERFORM core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
  SELECT id INTO v_ov FROM agent.chat_prompts WHERE payload->>'role' = 'overview' AND (payload->>'pass')::int = 2;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:go', v_ov), 'chat_id','111','chat_type','private'));
  FOR v_n IN 1..2 LOOP
    r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',false));
    EXIT WHEN (r->>'send')::boolean IS NOT TRUE;
    r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:keep', r->>'prompt_id'), 'chat_id','111','chat_type','private'));
  END LOOP;
  IF r->>'then' <> 'continue' OR position('publish' IN r->'continue'->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL [5 Auftrag veroeffentlichen]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__ck__','chat_id','111','plan_md','# Plan',
         'check_findings','[]','check_passes',1));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5 publish]: %', r; END IF;
  SELECT check_passes, jsonb_array_length(check_findings) INTO v_n, v_ov FROM agent.advisor_plans WHERE id = v_plan;
  IF v_n <> 2 OR v_ov <> 4 THEN RAISE EXCEPTION 'FAIL [5 aus den Zeilen: passes %, findings %]', v_n, v_ov; END IF;
  RAISE NOTICE 'PASS [5 letzter Durchgang + Publish]';
END $$;

ROLLBACK;
