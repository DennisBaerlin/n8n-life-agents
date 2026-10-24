-- tests/db/estate/test_fn_set_funeral_preferences.sql
-- WS-2: Bestattungswuensche-UPSERT (1 Zeile je Person) — Tri-State has_prepaid_contract
-- (nur explizit gesendeter Wert aendert), burial_type-Guard, Kind-Reject. Self-contained.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
  v_raised BOOLEAN := FALSE;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','kid','first_name','Kim','last_name','Beispiel',
                                 'role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- Kind-Reject:
  v_r := estate.fn_set_funeral_preferences(jsonb_build_object(
      'chat_id','333', 'person_id','erika', 'burial_type','erdbestattung'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Happy Path (Tri-State explizit true):
  v_r := estate.fn_set_funeral_preferences(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'burial_type','feuerbestattung',
      'has_prepaid_contract','true', 'prepaid_contract_provider','Bestattungshaus Muster'));
  IF NOT (v_r->>'ok')::boolean OR NOT (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [happy path]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.funeral_preferences
   WHERE person_id = 'erika' AND burial_type = 'feuerbestattung' AND has_prepaid_contract IS TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [happy path]: Zeile nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [UPSERT-Create + Vorsorgevertrag true]';

  -- Tri-State: Update OHNE has_prepaid_contract -> bleibt true (nicht gesendet = unveraendert):
  v_r := estate.fn_set_funeral_preferences(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'wishes','Seebestattung lieber nicht; Musik: Ave Maria'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [upsert update]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.funeral_preferences
   WHERE person_id = 'erika' AND has_prepaid_contract IS TRUE AND wishes LIKE 'Seebestattung%';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [Tri-State]: has_prepaid_contract nicht bewahrt'; END IF;
  RAISE NOTICE 'PASS [Tri-State: ungesendeter Bool bleibt unveraendert]';

  -- Guards:
  v_r := estate.fn_set_funeral_preferences(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'burial_type','weltraumbestattung'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid burial_type]: %', v_r; END IF;
  v_r := estate.fn_set_funeral_preferences(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'has_prepaid_contract','vielleicht'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid bool]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Guards: burial_type/bool -> ok:false]';

  -- Unbekannte Person: FK-Backstop RAISE (kein agent.persons-Read; der Tool-Resolve ist der Guard):
  BEGIN
    v_r := estate.fn_set_funeral_preferences(jsonb_build_object(
        'chat_id','111', 'person_id','fremder', 'burial_type','erdbestattung'));
  EXCEPTION WHEN foreign_key_violation THEN v_raised := TRUE;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [unknown person]: erwartet foreign_key_violation (FK-Backstop)'; END IF;
  RAISE NOTICE 'PASS [unbekannte Person -> FK-Backstop RAISE]';
END $$;

ROLLBACK;
