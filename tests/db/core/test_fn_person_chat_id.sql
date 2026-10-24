-- tests/db/core/test_fn_person_chat_id.sql
-- agent.fn_person_chat_id (P2a): person_id -> telegram_user_id (= private chat_id), Umkehrung von fn_resolve_sender.
--   bekannt+gepairt -> chat_id; bekannt+UNGEPAIRT (kein telegram_user_id, Skelett) -> NULL; unbekannt -> NULL.
--   RAISE-frei (Caller skippt den Send bei NULL). Fixture: family owner(gepairt 111) + partner(gepairt 222) +
--   child(Skelett ohne telegram_user_id). BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;
DO $$
DECLARE v_chat bigint;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                           'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11'),
        jsonb_build_object('person_id','kid','first_name','Kid','last_name','M','role','child',
                           'birth_date','2015-01-01','as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- TEST 1: owner -> 111 (private chat_id = telegram_user_id)
  v_chat := agent.fn_person_chat_id('erika');
  IF v_chat IS DISTINCT FROM 111 THEN RAISE EXCEPTION 'FAIL [1] erika chat_id erwartet 111, got %', v_chat; END IF;
  RAISE NOTICE 'PASS [1] owner -> eigene private chat_id (111)';

  -- TEST 2: 2. Person (partner) -> 222 (eigene, NICHT owner)
  v_chat := agent.fn_person_chat_id('lena');
  IF v_chat IS DISTINCT FROM 222 THEN RAISE EXCEPTION 'FAIL [2] lena chat_id erwartet 222, got %', v_chat; END IF;
  RAISE NOTICE 'PASS [2] 2. Person -> eigene chat_id (222)';

  -- TEST 3: bekannt aber UNGEPAIRT (Skelett ohne telegram_user_id) -> NULL (Caller skippt Send graceful)
  v_chat := agent.fn_person_chat_id('kid');
  IF v_chat IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3] ungepairtes Skelett erwartet NULL, got %', v_chat; END IF;
  RAISE NOTICE 'PASS [3] bekannt+ungepairt -> NULL (kein RAISE)';

  -- TEST 4: unbekannte person_id -> NULL
  v_chat := agent.fn_person_chat_id('nobody');
  IF v_chat IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4] unbekannte person erwartet NULL, got %', v_chat; END IF;
  RAISE NOTICE 'PASS [4] unbekannte person -> NULL';
END $$;
ROLLBACK;
