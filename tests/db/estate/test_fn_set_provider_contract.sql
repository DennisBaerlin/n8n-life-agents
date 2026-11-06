-- tests/db/estate/test_fn_set_provider_contract.sql
-- WS-2: partielles Vertrags-Update — COALESCE-Idiom ("nicht gesendet = unveraendert"),
-- Enum-Guards, Kind-Reject, not-found = RAISE (echte Ausnahme hinter dem Tool-Resolve).
-- Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r  JSONB;
  v_id BIGINT;
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

  INSERT INTO estate.provider_contracts (provider, category, customer_no)
  VALUES ('Telekom', 'telecom', 'KD-1') RETURNING id INTO v_id;

  -- Kind-Reject:
  v_r := estate.fn_set_provider_contract(jsonb_build_object(
      'chat_id','333', 'provider_contract_id',v_id, 'death_action','cancel'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Partielles Update: nur death_action + contract_no — provider/category/customer_no bewahrt:
  v_r := estate.fn_set_provider_contract(jsonb_build_object(
      'chat_id','111', 'provider_contract_id',v_id, 'death_action','cancel', 'contract_no','V-99'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [set]: %', v_r; END IF;
  PERFORM 1 FROM estate.provider_contracts
   WHERE id = v_id AND provider = 'Telekom' AND category = 'telecom'
     AND customer_no = 'KD-1' AND contract_no = 'V-99' AND death_action = 'cancel';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [partial update]: Felder nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [partielles Update: gesendet aktualisiert, ungesendet bewahrt]';

  -- Guards:
  v_r := estate.fn_set_provider_contract(jsonb_build_object(
      'chat_id','111', 'provider_contract_id',v_id, 'death_action','explode'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid death_action]: %', v_r; END IF;
  v_r := estate.fn_set_provider_contract(jsonb_build_object(
      'chat_id','111', 'provider_contract_id',v_id, 'new_category','frobnicate'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid new_category]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Guards -> ok:false]';

  -- not-found = RAISE (echte Ausnahme — der Tool-Resolve haette greifen muessen):
  BEGIN
    v_r := estate.fn_set_provider_contract(jsonb_build_object(
        'chat_id','111', 'provider_contract_id',999999, 'contract_no','x'));
  EXCEPTION WHEN OTHERS THEN v_raised := TRUE;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [not-found]: kein RAISE'; END IF;
  RAISE NOTICE 'PASS [not-found -> RAISE (Backstop)]';
END $$;

ROLLBACK;
