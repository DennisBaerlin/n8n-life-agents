-- tests/db/estate/test_fn_create_digital_account.sql
-- WS-2: Digitaler-Nachlass-Anlage — Schluesselkonto-Flag (toleranter Bool-Parse), crypto-
-- Kopplung des Seed-Fundorts (freundliche CHECK-Spiegelung), Enum-Guards, Kind-Reject.
-- Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
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
  v_r := estate.fn_create_digital_account(jsonb_build_object(
      'chat_id','333', 'provider','GMX', 'category','email'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Happy Path: Schluesselkonto mit tolerantem Bool ("True" via lower -> true):
  v_r := estate.fn_create_digital_account(jsonb_build_object(
      'chat_id','111', 'owner_person_id','erika', 'provider','GMX', 'category','email',
      'username','erika@gmx.de', 'is_key_account','True',
      'access_path','Passwort-Manager Bitwarden, Master-Passwort im Tresor'));
  IF NOT (v_r->>'ok')::boolean OR NOT (v_r->>'is_key_account')::boolean THEN
    RAISE EXCEPTION 'FAIL [happy path key account]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.digital_accounts
   WHERE id = (v_r->>'digital_account_id')::bigint AND is_key_account AND username = 'erika@gmx.de';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [happy path]: Zeile nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [create: Schluesselkonto, toleranter Bool-Parse]';

  -- crypto-Kopplung: Seed-Fundort auf Nicht-crypto -> freundliche Spiegelung des CHECKs:
  v_r := estate.fn_create_digital_account(jsonb_build_object(
      'chat_id','111', 'provider','Coinbase', 'category','email',
      'seed_backup_location','Metallplatte im Schliessfach'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%crypto%' THEN
    RAISE EXCEPTION 'FAIL [seed non-crypto]: %', v_r;
  END IF;
  v_r := estate.fn_create_digital_account(jsonb_build_object(
      'chat_id','111', 'provider','Ledger Wallet', 'category','crypto',
      'seed_backup_location','Metallplatte im Schliessfach'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [seed crypto]: %', v_r; END IF;
  RAISE NOTICE 'PASS [seed_backup_location: nur crypto (freundliche CHECK-Spiegelung)]';

  -- Guards:
  v_r := estate.fn_create_digital_account(jsonb_build_object(
      'chat_id','111', 'provider','X', 'category','frobnicate'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid category]: %', v_r; END IF;
  v_r := estate.fn_create_digital_account(jsonb_build_object(
      'chat_id','111', 'provider','X', 'category','social', 'desired_action','archive'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid desired_action]: %', v_r; END IF;
  v_r := estate.fn_create_digital_account(jsonb_build_object(
      'chat_id','111', 'provider','X', 'category','social', 'is_key_account','vielleicht'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid bool]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Guards: category/desired_action/is_key_account -> ok:false]';
END $$;

ROLLBACK;
