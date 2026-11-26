-- tests/db/core/test_handoff_task_states.sql
-- Gesetz der Vormerkung (agent.handoff_tasks, Trigger agent.fn_handoff_tasks_final_guard + CHECKs):
--   * Uebergaenge open -> deferred -> working -> done, deferred -> cancelled; nie aus einem Endzustand, nie deferred -> open/done;
--   * blocked_code genau bei deferred, Form eines festen Schluessels;
--   * wanted nach dem Anlegen unveraenderlich (auch nicht von NULL auf einen Wert);
--   * why hoechstens 160 Zeichen; entered_refs nur an done, nur Objekte {type, id}, an done nur anhaengbar;
--   * close_reason passt zum Endzustand; follows_task_id faellt beim Loeschen der Vorgaenger-Aufgabe auf NULL.
BEGIN;

DO $$
DECLARE
  v_id  int; v_id2 int; v_id3 int;
  v_ok  boolean;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM agent.handoff_tasks;

  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, why, wanted)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'savings_goal', 'Sparziel Urlaub 1.200 €', 'Damit der Urlaub bezahlt ist.',
          '{"tool":"create_savings_goal","input":{"name":"Urlaub","target_amount":1200}}')
  RETURNING id INTO v_id;

  -- ---------- 1) open -> deferred -> working -> done ----------
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET status = 'deferred' WHERE id = v_id;
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [1 deferred ohne blocked_code]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = 'Ende in Zukunft' WHERE id = v_id;
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [1 blocked_code ohne Schluessel-Form]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET blocked_code = 'end_date_future' WHERE id = v_id;
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [1 blocked_code an open]'; END IF;
  UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = 'end_date_future' WHERE id = v_id;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET status = 'open', blocked_code = NULL WHERE id = v_id;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [1 deferred -> open erlaubt]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET status = 'done', blocked_code = NULL, closed_at = now() WHERE id = v_id;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [1 deferred -> done erlaubt]'; END IF;
  UPDATE agent.handoff_tasks SET status = 'working', blocked_code = NULL, claimed_at = now() WHERE id = v_id;
  UPDATE agent.handoff_tasks SET status = 'done', closed_at = now(), close_reason = 'entered',
         entered_refs = '[{"type":"savings_goal","id":7}]' WHERE id = v_id;
  RAISE NOTICE 'PASS [1 open -> deferred -> working -> done, blocked_code genau bei deferred]';

  -- ---------- 2) Endzustand: nur entered_refs anhaengen ----------
  UPDATE agent.handoff_tasks SET entered_refs = '[{"type":"savings_goal","id":7},{"type":"recurring_payment","id":3}]' WHERE id = v_id;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET entered_refs = '[{"type":"recurring_payment","id":3}]' WHERE id = v_id;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [2 entered_refs gekuerzt]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET text = 'anders' WHERE id = v_id;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [2 Endzustand geaendert]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET status = 'working' WHERE id = v_id;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [2 Endzustand wieder geoeffnet]'; END IF;
  RAISE NOTICE 'PASS [2 Endzustand unveraenderlich bis auf angehaengte entered_refs]';

  -- ---------- 3) wanted unveraenderlich ----------
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'other', 'Haftpflicht pruefen') RETURNING id INTO v_id2;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET wanted = '{"tool":"x","input":{}}' WHERE id = v_id2;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [3 wanted nachtraeglich gesetzt]'; END IF;
  v_ok := false;
  BEGIN INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, wanted)
        VALUES ('finance', 'finance', 'erika', 'g', 'other', 't', '"text"');
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [3 wanted als Zeichenkette]'; END IF;
  -- einzige Ausnahme: beim Nachholen (deferred -> working) einmal von NULL auf den Aufruf der Vorpruefung
  UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = 'tool_missing' WHERE id = v_id2;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET wanted = '{"tool":"x","input":{}}' WHERE id = v_id2;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [3 wanted an deferred ohne Nachholen]'; END IF;
  UPDATE agent.handoff_tasks SET status = 'working', blocked_code = NULL, claimed_at = now(), wanted = '{"tool":"x","input":{}}' WHERE id = v_id2;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET wanted = '{"tool":"y","input":{}}' WHERE id = v_id2;
  EXCEPTION WHEN raise_exception THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [3 wanted zweimal gesetzt]'; END IF;
  UPDATE agent.handoff_tasks SET status = 'open' WHERE id = v_id2;
  RAISE NOTICE 'PASS [3 wanted unveraenderlich, ausser einmal beim Nachholen]';

  -- ---------- 4) why, entered_refs, close_reason ----------
  v_ok := false;
  BEGIN INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, why)
        VALUES ('finance', 'finance', 'erika', 'g', 'other', 't', repeat('a', 161));
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [4 why ueber 160]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET entered_refs = '[{"type":"x","id":1}]' WHERE id = v_id2;
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [4 entered_refs an open]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET status = 'cancelled', closed_at = now(), close_reason = 'entered' WHERE id = v_id2;
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [4 close_reason entered an cancelled]'; END IF;
  v_ok := false;
  BEGIN UPDATE agent.handoff_tasks SET status = 'done', closed_at = now(), close_reason = 'entered', entered_refs = '[{"id":1}]' WHERE id = v_id2;
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [4 entered_refs ohne type]'; END IF;
  UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = 'tool_missing' WHERE id = v_id2;
  UPDATE agent.handoff_tasks SET status = 'cancelled', blocked_code = NULL, closed_at = now(), close_reason = 'dropped' WHERE id = v_id2;
  RAISE NOTICE 'PASS [4 why, entered_refs, close_reason, deferred -> cancelled]';

  -- ---------- 5) Korrektur = neue Aufgabe mit follows_task_id ----------
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, follows_task_id)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'other', 'Haftpflicht pruefen', v_id2) RETURNING id INTO v_id3;
  DELETE FROM agent.handoff_tasks WHERE id = v_id2;
  IF (SELECT follows_task_id FROM agent.handoff_tasks WHERE id = v_id3) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 SET NULL]'; END IF;
  -- auch an einer abgeschlossenen Nachfolgerin darf das Loeschen der Vorgaengerin nicht scheitern
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at, close_reason, follows_task_id)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'other', 'Nachfolge', 'cancelled', now(), 'dropped', v_id3);
  DELETE FROM agent.handoff_tasks WHERE id = v_id3;
  RAISE NOTICE 'PASS [5 follows_task_id ON DELETE SET NULL, auch an Endzustand]';
END $$;

ROLLBACK;
