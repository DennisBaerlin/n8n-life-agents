-- tests/db/estate/test_fn_create_special_asset.sql
-- WS-2: Sonderfall-Stub-Anlage — Happy Path, geschlossene Typ-Liste OHNE other (freundliche
-- CHECK-Spiegelung), Kind-Reject. Self-contained; BEGIN..ROLLBACK.
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
  v_r := estate.fn_create_special_asset(jsonb_build_object(
      'chat_id','333', 'asset_type','pet', 'description','Kater Milo'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Happy Path (Person-zugeordnetes Fahrzeug):
  v_r := estate.fn_create_special_asset(jsonb_build_object(
      'chat_id','111', 'owner_person_id','erika', 'asset_type','vehicle',
      'description','VW Golf, Kennzeichen MU-ST 123'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'special_asset_id') IS NULL THEN
    RAISE EXCEPTION 'FAIL [happy path]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.special_assets
   WHERE id = (v_r->>'special_asset_id')::bigint AND asset_type = 'vehicle' AND owner_person_id = 'erika';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [happy path]: Zeile nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [create: Fahrzeug-Stub gespeichert]';

  -- Geschlossene Liste OHNE other (offener Typ loeste im Ereignisfall still nichts aus):
  v_r := estate.fn_create_special_asset(jsonb_build_object(
      'chat_id','111', 'asset_type','other', 'description','Irgendwas'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%invalid asset_type%' THEN
    RAISE EXCEPTION 'FAIL [asset_type other]: %', v_r;
  END IF;
  v_r := estate.fn_create_special_asset(jsonb_build_object(
      'chat_id','111', 'asset_type','firearm', 'description',''));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [empty description]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Guards: asset_type (kein other!)/description -> ok:false]';
END $$;

ROLLBACK;
