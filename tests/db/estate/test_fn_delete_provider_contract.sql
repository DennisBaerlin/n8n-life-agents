-- tests/db/estate/test_fn_delete_provider_contract.sql
-- WS-2: Vertrags-Loeschung — Kategorie-Filter disambiguiert, Ambiguitaet/not-found = RAISE
-- (Backstop hinter dem Tool-Resolve), Kind-Reject VOR dem Resolve. Self-contained.
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

  INSERT INTO estate.provider_contracts (provider, category) VALUES
      ('Telekom', 'telecom'), ('Telekom', 'media');

  -- Kind-Reject (VOR Resolve/Delete):
  v_r := estate.fn_delete_provider_contract(jsonb_build_object('chat_id','333', 'provider','Telekom'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.provider_contracts;
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [child reject]: Delete trotz Reject'; END IF;
  RAISE NOTICE 'PASS [Kind-Reject: kein Delete]';

  -- Ambiguitaet ohne Filter -> RAISE (Backstop; das Tool loest vor dem Gate auf):
  v_r := estate.fn_delete_provider_contract(jsonb_build_object('chat_id','111', 'provider','Telekom'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' NOT IN ('not_found', 'ambiguous') OR NOT (v_r ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL [ambiguous -> ok:false]: %', v_r; END IF;
  RAISE NOTICE 'PASS [ambig ohne Filter -> ok:false (Probelauf vor der Karte)]';

  -- Kategorie-Filter disambiguiert -> genau EINE Zeile weg:
  v_r := estate.fn_delete_provider_contract(jsonb_build_object(
      'chat_id','111', 'provider','Telekom', 'category','media'));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'action' <> 'deleted' THEN
    RAISE EXCEPTION 'FAIL [delete]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.provider_contracts WHERE provider = 'Telekom';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [delete]: % Zeilen statt 1', v_n; END IF;
  PERFORM 1 FROM estate.provider_contracts WHERE provider = 'Telekom' AND category = 'telecom';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [delete]: falsche Zeile geloescht'; END IF;
  RAISE NOTICE 'PASS [Kategorie-Filter loescht genau die richtige Zeile]';

  -- not-found -> RAISE:
  v_raised := FALSE;
  v_r := estate.fn_delete_provider_contract(jsonb_build_object('chat_id','111', 'provider','GibtsNicht'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' NOT IN ('not_found', 'ambiguous') OR NOT (v_r ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL [not-found -> ok:false]: %', v_r; END IF;
  RAISE NOTICE 'PASS [not-found -> ok:false (Probelauf vor der Karte)]';
END $$;

ROLLBACK;
