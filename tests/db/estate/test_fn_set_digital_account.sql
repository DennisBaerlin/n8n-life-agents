-- tests/db/estate/test_fn_set_digital_account.sql
-- WS-2: partielles Digital-Konto-Update — crypto-Kopplung gegen die EFFEKTIVE Kategorie
-- (bestehend + Kategorie-Wechsel im selben Call), toleranter Bool, Kind-Reject.
-- Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r  JSONB;
  v_id BIGINT;
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

  INSERT INTO estate.digital_accounts (provider, category, username)
  VALUES ('Google', 'email', 'erika@gmail.com') RETURNING id INTO v_id;

  -- Kind-Reject:
  v_r := estate.fn_set_digital_account(jsonb_build_object(
      'chat_id','333', 'digital_account_id',v_id, 'desired_action','keep'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Partielles Update + toleranter Bool:
  v_r := estate.fn_set_digital_account(jsonb_build_object(
      'chat_id','111', 'digital_account_id',v_id, 'desired_action','transfer', 'is_key_account','yes',
      'legacy_contact_status','configured'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [set]: %', v_r; END IF;
  PERFORM 1 FROM estate.digital_accounts
   WHERE id = v_id AND provider = 'Google' AND username = 'erika@gmail.com'
     AND desired_action = 'transfer' AND is_key_account AND legacy_contact_status = 'configured';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [partial update]: Felder nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [partielles Update + toleranter Bool-Parse]';

  -- crypto-Kopplung gegen die EFFEKTIVE Kategorie:
  v_r := estate.fn_set_digital_account(jsonb_build_object(
      'chat_id','111', 'digital_account_id',v_id, 'seed_backup_location','Schliessfach'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%crypto%' THEN
    RAISE EXCEPTION 'FAIL [seed auf email]: %', v_r;
  END IF;
  v_r := estate.fn_set_digital_account(jsonb_build_object(
      'chat_id','111', 'digital_account_id',v_id, 'new_category','crypto',
      'seed_backup_location','Metallplatte im Schliessfach'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [Kategorie-Wechsel + Seed]: %', v_r; END IF;
  PERFORM 1 FROM estate.digital_accounts
   WHERE id = v_id AND category = 'crypto' AND seed_backup_location = 'Metallplatte im Schliessfach';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [Kategorie-Wechsel]: nicht gespeichert'; END IF;
  RAISE NOTICE 'PASS [crypto-Kopplung: effektive Kategorie (bestehend + Wechsel im selben Call)]';
END $$;

ROLLBACK;
