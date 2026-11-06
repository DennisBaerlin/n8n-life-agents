-- tests/db/estate/test_fn_delete_special_asset.sql
-- WS-2: Sonderfall-Stub-Loeschung (verkauft/abgegeben — Stubs haben keinen Lifecycle-Status;
-- ein verkauftes Fahrzeug MUSS raus, sonst falsche WS-3-Checklisten-Tasks) — Typ-Filter,
-- not-found = RAISE, Kind-Reject. Self-contained; BEGIN..ROLLBACK.
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

  INSERT INTO estate.special_assets (asset_type, description) VALUES
      ('vehicle', 'VW Golf'), ('pet', 'Kater Milo');

  -- Kind-Reject:
  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','333', 'description','VW Golf'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Delete (exakte Beschreibung):
  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111', 'description','VW Golf'));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'action' <> 'deleted' THEN
    RAISE EXCEPTION 'FAIL [delete]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.special_assets;
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [delete]: % Zeilen statt 1', v_n; END IF;
  PERFORM 1 FROM estate.special_assets WHERE asset_type = 'pet';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [delete]: falsche Zeile geloescht'; END IF;
  RAISE NOTICE 'PASS [Delete: genau der richtige Stub weg]';

  -- not-found -> RAISE:
  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111', 'description','GibtsNicht'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' NOT IN ('not_found', 'ambiguous') OR NOT (v_r ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL [not-found -> ok:false]: %', v_r; END IF;
  RAISE NOTICE 'PASS [not-found -> ok:false (Probelauf vor der Karte)]';
END $$;

ROLLBACK;
