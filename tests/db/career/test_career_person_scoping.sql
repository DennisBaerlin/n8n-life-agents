-- tests/db/career/test_career_person_scoping.sql
-- P2a: career.job_matches ist wholly-per-person. Beweist die DB-Invarianten:
--   (1) person_id NOT NULL (kein Haushalts-Job-Match)
--   (2) FK -> agent.persons ON DELETE RESTRICT (eine Person mit Treffern ist nicht loeschbar)
--   (3) Partial-UNIQUE (source, external_id, person_id): zwei Personen fuehren DASSELBE Posting (gleiche source+external_id) je EINMAL
--       (Person-Isolation), Re-Scan derselben Person UPSERTet (kein Dup).
-- Fixture: family owner(erika) + partner(lena) -> projiziert nach agent.persons (FK-Ziel). BEGIN..ROLLBACK.
BEGIN;
DO $$
DECLARE
  v_cnt int; v_denied boolean; r jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                           'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- TEST 1: person_id NOT NULL (direkter INSERT ohne person_id -> not_null_violation)
  v_denied := false;
  BEGIN
    INSERT INTO career.job_matches (source, external_id, title) VALUES ('forwarded', 'NN1', 'Ohne Person');
  EXCEPTION WHEN not_null_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [1] job_matches.person_id NOT NULL nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [1] person_id NOT NULL erzwungen';

  -- TEST 2: per-Person-Koexistenz desselben Postings (gleiche external_id, zwei Personen -> ZWEI Zeilen)
  r := career.fn_record_job_match(jsonb_build_object('person_id','erika','source','bundesagentur','external_id','SHARED','title','SM','score',3));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'created')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [2a] erika SHARED: %', r; END IF;
  r := career.fn_record_job_match(jsonb_build_object('person_id','lena','source','bundesagentur','external_id','SHARED','title','SM','score',2));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'created')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [2b] lena SHARED soll EIGENE Zeile (created=true) sein: %', r; END IF;
  SELECT count(*) INTO v_cnt FROM career.job_matches WHERE external_id='SHARED';
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [2c] erwartet 2 Zeilen (erika+lena) fuer SHARED, got %', v_cnt; END IF;
  -- Re-Scan derselben Person -> UPSERT (kein Dup, created=false)
  r := career.fn_record_job_match(jsonb_build_object('person_id','erika','source','bundesagentur','external_id','SHARED','title','SM (m/w/d)','score',4));
  IF (r->>'created')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [2d] erika Re-Scan soll UPSERT (created=false): %', r; END IF;
  SELECT count(*) INTO v_cnt FROM career.job_matches WHERE external_id='SHARED';
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [2e] Re-Scan erzeugte Dup (erwartet 2, got %)', v_cnt; END IF;
  RAISE NOTICE 'PASS [2] per-Person-external_id-Koexistenz (2 Personen = 2 Zeilen, Re-Scan = UPSERT)';

  -- TEST 3: FK ON DELETE RESTRICT — eine Person mit Treffern ist nicht loeschbar
  v_denied := false;
  BEGIN
    DELETE FROM agent.persons WHERE person_id = 'erika';
  EXCEPTION WHEN foreign_key_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [3] DELETE einer Person mit job_matches nicht durch FK RESTRICT geblockt'; END IF;
  RAISE NOTICE 'PASS [3] FK ON DELETE RESTRICT (Person mit Treffern nicht loeschbar)';
END $$;
ROLLBACK;
