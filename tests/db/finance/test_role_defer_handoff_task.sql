-- tests/db/finance/test_role_defer_handoff_task.sql
-- Rollen-Perspektive des Werkzeugs agent.finance.tool_defer_handoff_task: finance.fn_defer_handoff_task laeuft unter
--   finance_rw (Probelauf ueber core.fn_dry_run und echter Write) und erreicht agent.handoff_tasks nur ueber das
--   DEFINER-Fenster core.fn_defer_handoff_task. Geprueft: Probelauf laesst die Aufgabe working und liefert die Kartenzeile,
--   Write setzt deferred + blocked_code, unbekannter Code -> unknown_blocked_code ohne Write.
BEGIN;

DO $$
DECLARE
  r   jsonb;
  v_t int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.ui_texts (key, lang, text, package)
  VALUES ('finance.handoff.blocked.pay_until_amount', 'de', 'Zahlung bis Betrag geht noch nicht.', 'finance')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  DELETE FROM agent.handoff_tasks;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','recurring_transfer','Übertrag bis zu einem Zielstand','working',now())
  RETURNING id INTO v_t;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_defer_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_t::text, 'chat_id', '111', 'blocked_code', 'pay_until_amount'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'card_lines'->0->>'value' IS DISTINCT FROM 'core.hitl.handoff_pos'
     OR r->'card_lines'->1->>'value' IS DISTINCT FROM 'core.hitl.handoff_note'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'working' THEN RAISE EXCEPTION 'FAIL [1 Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_t::text, 'chat_id', '111', 'blocked_code', 'kein_code'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'unknown_blocked_code'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'working' THEN RAISE EXCEPTION 'FAIL [2 unbekannter Code]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_t::text, 'chat_id', '111', 'blocked_code', 'pay_until_amount'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'deferred'
     OR NOT EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE id = v_t AND status = 'deferred' AND blocked_code = 'pay_until_amount')
     THEN RAISE EXCEPTION 'FAIL [3 Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_defer_handoff_task';
END $$;

ROLLBACK;
