-- tests/db/estate/test_fn_set_person_record.sql
-- WS-2: Stammdaten-UPSERT (1 Zeile je Person) — Format-NORMALISIERUNG (Steuer-ID/RV-Nr.
-- leerzeichen-bereinigt, RV upper) + freundliche Regex-Spiegelung der Gesetz-CHECKs,
-- partielles Update, unbekannte Person, Kind-Reject. Self-contained; BEGIN..ROLLBACK.
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
  v_r := estate.fn_set_person_record(jsonb_build_object(
      'chat_id','333', 'person_id','kid', 'employer','Schule'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Happy Path + Normalisierung (Leerzeichen raus, RV upper; DB rechnet/normalisiert, nie das LLM):
  v_r := estate.fn_set_person_record(jsonb_build_object(
      'chat_id','111', 'person_id','erika',
      'tax_id','12 345 678 901', 'pension_insurance_no','12 190680 m 007',
      'health_insurance_type','GKV', 'health_insurance_name','TK'));
  IF NOT (v_r->>'ok')::boolean OR NOT (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [happy path]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.person_records
   WHERE person_id = 'erika' AND tax_id = '12345678901'
     AND pension_insurance_no = '12190680M007' AND health_insurance_type = 'gkv';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [Normalisierung]: kanonische Formate nicht gespeichert'; END IF;
  RAISE NOTICE 'PASS [UPSERT-Create + Steuer-ID/RV-Normalisierung (Leerzeichen/upper)]';

  -- Partielles Update (UPSERT-Zweig): nur employer — Kennnummern bewahrt:
  v_r := estate.fn_set_person_record(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'employer','Beispiel GmbH'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [upsert update]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.person_records
   WHERE person_id = 'erika' AND tax_id = '12345678901' AND employer = 'Beispiel GmbH';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [partial update]: Felder nicht bewahrt'; END IF;
  RAISE NOTICE 'PASS [partielles UPSERT-Update: created=false, Bestand bewahrt]';

  -- Freundliche Regex-Spiegelung (Gesetz-CHECKs):
  v_r := estate.fn_set_person_record(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'tax_id','1234567890'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%11 digits%' THEN
    RAISE EXCEPTION 'FAIL [invalid tax_id]: %', v_r;
  END IF;
  v_r := estate.fn_set_person_record(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'pension_insurance_no','ABC'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid RV]: %', v_r; END IF;
  v_r := estate.fn_set_person_record(jsonb_build_object(
      'chat_id','111', 'person_id','erika', 'health_insurance_type','privatkasse'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid hi_type]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Format-Guards: tax_id/RV/hi_type -> ok:false]';

  -- Unbekannte Person (kein Haushaltsmitglied): der Tool-Resolve ist der Guard; erreicht ein bogus
  -- person_id die fn direkt, faengt die FK person_id -> agent.persons(person_id) sie ab (echte
  -- Ausnahme, kein {ok:false}) — KEIN expliziter agent.persons-Read (der crashte unter estate_rw).
  BEGIN
    v_r := estate.fn_set_person_record(jsonb_build_object(
        'chat_id','111', 'person_id','fremder', 'employer','X'));
  EXCEPTION WHEN foreign_key_violation THEN v_raised := TRUE;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [unknown person]: erwartet foreign_key_violation (FK-Backstop), kein Wurf'; END IF;
  RAISE NOTICE 'PASS [unbekannte Person -> FK-Backstop RAISE (kein agent.persons-Read)]';
END $$;

ROLLBACK;
