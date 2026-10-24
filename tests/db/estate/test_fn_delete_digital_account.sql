-- tests/db/estate/test_fn_delete_digital_account.sql
-- WS-2: Digital-Konto-Loeschung — Nutzername-Filter disambiguiert, Ambiguitaet = RAISE,
-- Kind-Reject VOR dem Resolve. Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
  v_n INT;
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

  INSERT INTO estate.digital_accounts (provider, category, username) VALUES
      ('Google', 'email', 'erika@gmail.com'), ('Google', 'email', 'lena@gmail.com');

  -- Kind-Reject:
  v_r := estate.fn_delete_digital_account(jsonb_build_object('chat_id','333', 'provider','Google'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Ambiguitaet ohne Nutzername -> RAISE:
  v_r := estate.fn_delete_digital_account(jsonb_build_object('chat_id','111', 'provider','Google'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' NOT IN ('not_found', 'ambiguous') OR NOT (v_r ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL [ambiguous -> ok:false]: %', v_r; END IF;

  -- Nutzername-Filter -> genau die richtige Zeile weg:
  v_r := estate.fn_delete_digital_account(jsonb_build_object(
      'chat_id','111', 'provider','Google', 'username','lena@gmail.com'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [delete]: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM estate.digital_accounts WHERE provider = 'Google';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [delete]: % Zeilen statt 1', v_n; END IF;
  PERFORM 1 FROM estate.digital_accounts WHERE username = 'erika@gmail.com';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [delete]: falsche Zeile geloescht'; END IF;
  RAISE NOTICE 'PASS [Nutzername-Filter loescht genau die richtige Zeile; ambig -> RAISE]';
END $$;

ROLLBACK;
