-- tests/db/estate/test_fn_confirm_review.sql
-- WS-2: Review-Bestaetigung (Fortschritts-Flag-Klasse, kein HITL am Tool — der adults_only-
-- Backstop bleibt) — UPSERT-Stempel last_reviewed_at (Zeile entsteht bei Bedarf), Re-Stempel,
-- unbekannte Person, Kind-Reject. Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r  JSONB;
  v_t1 TIMESTAMPTZ;
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

  -- Kind-Reject (der Fortschritts-Flag-Klasse fehlt das Gate — der fn-Backstop MUSS tragen):
  v_r := estate.fn_confirm_review(jsonb_build_object('chat_id','333', 'person_id','erika'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject (fn-Backstop ohne Gate)]';

  -- UPSERT: Zeile existiert noch nicht -> entsteht mit Stempel:
  v_r := estate.fn_confirm_review(jsonb_build_object('chat_id','111', 'person_id','erika'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'last_reviewed_at') IS NULL THEN
    RAISE EXCEPTION 'FAIL [confirm create]: %', v_r;
  END IF;
  SELECT last_reviewed_at INTO v_t1 FROM estate.person_records WHERE person_id = 'erika';
  IF v_t1 IS NULL THEN RAISE EXCEPTION 'FAIL [confirm create]: kein Stempel'; END IF;
  RAISE NOTICE 'PASS [Review-Bestaetigung: Zeile entsteht mit last_reviewed_at]';

  -- Re-Stempel auf bestehender Zeile (>= erster Stempel; andere Felder unberuehrt):
  UPDATE estate.person_records SET employer = 'Beispiel GmbH' WHERE person_id = 'erika';
  v_r := estate.fn_confirm_review(jsonb_build_object('chat_id','111', 'person_id','erika'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [re-confirm]: %', v_r; END IF;
  PERFORM 1 FROM estate.person_records
   WHERE person_id = 'erika' AND last_reviewed_at >= v_t1 AND employer = 'Beispiel GmbH';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [re-confirm]: Stempel/Felder nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [Re-Stempel: aktualisiert, Bestand unberuehrt]';

  -- Unbekannte Person: FK-Backstop RAISE (kein agent.persons-Read; der Tool-Resolve ist der Guard):
  BEGIN
    v_r := estate.fn_confirm_review(jsonb_build_object('chat_id','111', 'person_id','fremder'));
  EXCEPTION WHEN foreign_key_violation THEN v_raised := TRUE;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [unknown person]: erwartet foreign_key_violation (FK-Backstop)'; END IF;
  RAISE NOTICE 'PASS [unbekannte Person -> FK-Backstop RAISE]';
END $$;

ROLLBACK;
