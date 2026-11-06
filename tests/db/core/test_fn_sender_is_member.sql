-- tests/db/core/test_fn_sender_is_member.sql
-- WS-5b — geteilter owner_only-Guard agent.fn_sender_is_member(chat_id text) -> boolean.
-- Semantik (konsistent mit dem Gate-„is_member"): TRUE nur bei POSITIV aufgeloestem Nicht-Owner
--   (chat_id numerisch ∧ fn_resolve_sender found:true ∧ role <> 'owner').
-- FALSE (durchlassen) bei: Owner · nicht in family (found:false) · nicht-numerisch (Test/Sentinel) · NULL.
-- Das ist der DB-Backstop, den die owner_only-Schreib-fns vorab aufrufen (RAISE-frei -> {ok:false}).
-- Fixture: family (erika owner@111, lena partner@222) in BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'sender_is_member fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','protected', true,
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11'),
              jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','Mustermann',
                                 'role','child','birth_date','2015-02-17','as_of','2026-06-11')
            ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  -- Owner (erika@111) -> FALSE (kein Block)
  IF agent.fn_sender_is_member('111') THEN
    RAISE EXCEPTION 'FAIL fn_sender_is_member [owner]: erwartet false, got true';
  END IF;
  RAISE NOTICE 'PASS fn_sender_is_member [owner -> false]';

  -- Gepairter Nicht-Owner (lena@222, partner) -> TRUE (Block)
  IF NOT agent.fn_sender_is_member('222') THEN
    RAISE EXCEPTION 'FAIL fn_sender_is_member [paired non-owner]: erwartet true, got false';
  END IF;
  RAISE NOTICE 'PASS fn_sender_is_member [gepairter partner -> true]';

  -- Numerisch, aber nicht in family (found:false) -> FALSE (durchlassen, anomal/Bootstrap)
  IF agent.fn_sender_is_member('999999') THEN
    RAISE EXCEPTION 'FAIL fn_sender_is_member [unknown numeric]: erwartet false, got true';
  END IF;
  RAISE NOTICE 'PASS fn_sender_is_member [unbekannte numerische id -> false]';

  -- Nicht-numerisch (E2E-Sentinel) -> FALSE (Resolver wird nie mit ::bigint gerufen)
  IF agent.fn_sender_is_member('test_e2e_ae01') THEN
    RAISE EXCEPTION 'FAIL fn_sender_is_member [sentinel]: erwartet false, got true';
  END IF;
  RAISE NOTICE 'PASS fn_sender_is_member [nicht-numerischer Sentinel -> false]';

  -- NULL / leer -> FALSE
  IF agent.fn_sender_is_member(NULL) OR agent.fn_sender_is_member('') THEN
    RAISE EXCEPTION 'FAIL fn_sender_is_member [null/empty]: erwartet false';
  END IF;
  RAISE NOTICE 'PASS fn_sender_is_member [NULL/leer -> false]';

  RAISE NOTICE 'PASS fn_sender_is_member [alle Faelle]';
END $$;

ROLLBACK;
