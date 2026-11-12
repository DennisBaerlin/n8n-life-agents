-- tests/db/core/test_monitor_child_view.sql
-- Kinder-Sicht im Monitor (Backstop zum Eingangs-Gate): agent.fn_monitor_probe, fn_create/set/delete_monitor_trigger
-- lehnen mit chat_id eines Absenders ohne Haushalts-Sicht ab, bevor beschafft oder geschrieben wird; ohne chat_id
-- (Cron/Systempfad) und fuer Erwachsene greift die Sperre nicht.
BEGIN;
DO $$
DECLARE
  r jsonb;
  n int;
  v_fn text;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','M','role','child','birth_date','2014-03-02','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  SELECT count(*) INTO n FROM agent.monitor_triggers;

  FOREACH v_fn IN ARRAY ARRAY['agent.fn_monitor_probe', 'agent.fn_create_monitor_trigger', 'agent.fn_set_monitor_trigger', 'agent.fn_delete_monitor_trigger'] LOOP
    EXECUTE format('SELECT %s($1)', v_fn) INTO r USING jsonb_build_object('chat_id', '333', 'acquisition_method', 'sql',
      'acquisition_sql', 'SELECT 1', 'label', '__cv_t__', 'domain', 'general', 'trigger_type', 'threshold');
    IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT LIKE 'household_only%' THEN
      RAISE EXCEPTION 'FAIL [Kind %]: %', v_fn, r; END IF;
    -- Erwachsener / ohne chat_id: die Sperre greift nicht (andere Gruende duerfen kommen)
    EXECUTE format('SELECT %s($1)', v_fn) INTO r USING jsonb_build_object('chat_id', '111', 'acquisition_method', 'sql',
      'acquisition_sql', 'SELECT 1', 'label', '__cv_t__', 'domain', 'general', 'trigger_type', 'threshold');
    IF COALESCE(r->>'reason', '') LIKE 'household_only%' THEN RAISE EXCEPTION 'FAIL [Owner %]: %', v_fn, r; END IF;
    -- unbekannte Zahl (Werkzeug-Harness ohne Person): Backstop greift nicht, das Tor vor Agenten ist fn_sender_sees_household
    EXECUTE format('SELECT %s($1)', v_fn) INTO r USING jsonb_build_object('chat_id', '999000111', 'acquisition_method', 'sql',
      'acquisition_sql', 'SELECT 1', 'label', '__cv_t__', 'domain', 'general', 'trigger_type', 'threshold');
    IF COALESCE(r->>'reason', '') LIKE 'household_only%' THEN RAISE EXCEPTION 'FAIL [unbekannt %]: %', v_fn, r; END IF;
  END LOOP;
  IF (SELECT count(*) FROM agent.monitor_triggers WHERE label = '__cv_t__' AND domain = 'general') > 1 THEN
    RAISE EXCEPTION 'FAIL [Kind hat geschrieben]'; END IF;
  RAISE NOTICE 'PASS test_monitor_child_view';
END $$;
ROLLBACK;
