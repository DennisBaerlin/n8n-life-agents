-- tests/db/core/test_fn_owner_person_id.sql
-- agent.fn_owner_person_id (P0c): die EINE deterministische Owner-Anker-Quelle (family.facts WHERE role='owner'
-- LIMIT 1). MUSS deterministisch + RAISE-frei sein (Konsumenten: read_plan-Fallback, career.fn_advisor_review,
-- cron.refresh_market_signals, V002 — die Review-fn darf NIE RAISEn). Kein Owner -> NULL.
BEGIN;
DO $$
DECLARE v_owner TEXT;
BEGIN
  -- ---------- TEST 1: kein family -> NULL (Bootstrap), kein RAISE ----------
  DELETE FROM agent.core_contexts WHERE name = 'family';
  v_owner := agent.fn_owner_person_id();
  IF v_owner IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1] ohne family erwartet NULL, got %', v_owner; END IF;
  RAISE NOTICE 'PASS [1] kein family -> NULL (kein RAISE)';

  -- ---------- TEST 2: Owner aus family.facts.persons[] (role=owner) ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M',
                           'role','owner','birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B',
                           'role','partner','birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  v_owner := agent.fn_owner_person_id();
  IF v_owner IS DISTINCT FROM 'erika' THEN RAISE EXCEPTION 'FAIL [2] erwartet erika, got %', v_owner; END IF;
  RAISE NOTICE 'PASS [2] Owner-Slug aus family (role=owner) -> erika';

  -- ---------- TEST 3 (RAISE-Schutz): zwei owner-Zeilen -> LIMIT 1, KEIN "more than one row" ----------
  -- agent.persons/der family-Validator erzwingen KEINE owner-Eindeutigkeit -> ohne LIMIT 1 wuerfe ein
  -- Scalar-Subquery hier "more than one row" und kippte die RAISE-verbotene career.fn_advisor_review.
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                         'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
      jsonb_build_object('person_id','zweitowner','first_name','Z','last_name','O','role','owner',
                         'birth_date','1979-01-01','telegram_user_id',333,'as_of','2026-06-11')))
    WHERE name = 'family';
  BEGIN
    v_owner := agent.fn_owner_person_id();   -- darf NICHT werfen
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FAIL [3] zwei owner -> RAISE (LIMIT 1 fehlt): %', SQLERRM;
  END;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'FAIL [3] zwei owner -> NULL statt eines Slugs'; END IF;
  RAISE NOTICE 'PASS [3] zwei owner-Zeilen -> LIMIT 1 (deterministisch, kein RAISE)';
END $$;
ROLLBACK;
