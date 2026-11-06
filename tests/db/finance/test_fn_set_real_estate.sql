-- tests/db/finance/test_fn_set_real_estate.sql
-- Testet fn_set_real_estate: Neubewertung (value_updated_at auto), Status, partielles Update, neg-Wert
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_id     INT;
  v_val    NUMERIC;
  v_vdate  DATE;
  v_status TEXT;
  v_person TEXT;
BEGIN

  -- WS-4 Fixture: eine Person als typisierter Eigentuemer (owner_person_id, kein Freitext mehr)
  INSERT INTO agent.persons (person_id, full_name, role)
  VALUES ('__test_setre_p', 'Test Eigentuemer', 'owner') ON CONFLICT (person_id) DO NOTHING;

  SELECT finance.fn_create_real_estate(
    '{"name":"__test_set_re__","current_value":300000,"owner_person_id":"__test_setre_p","status":"active"}'::jsonb
  ) INTO v_res;
  v_id := (v_res->>'real_estate_id')::int;

  -- TEST 1: Neubewertung ohne value_updated_at -> Wert gesetzt + value_updated_at = heute; owner_person_id stabil
  SELECT finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_id, 'current_value', 350000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_real_estate [ok]: %', v_res;
  END IF;
  SELECT current_value, value_updated_at, owner_person_id INTO v_val, v_vdate, v_person
  FROM finance.real_estate WHERE id = v_id;
  IF v_val IS DISTINCT FROM 350000 THEN
    RAISE EXCEPTION 'FAIL set_real_estate [value]: erwartet 350000, got %', v_val;
  END IF;
  IF v_vdate IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL set_real_estate [value_updated_at auto]: erwartet heute, got %', v_vdate;
  END IF;
  IF v_person IS DISTINCT FROM '__test_setre_p' THEN
    RAISE EXCEPTION 'FAIL set_real_estate [partial]: owner_person_id duerfte nicht geaendert sein, got %', v_person;
  END IF;
  RAISE NOTICE 'PASS set_real_estate [Neubewertung: value=350000, value_updated_at=heute, owner_person_id stabil]';

  -- TEST 2: Status auf sold
  SELECT finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_id, 'status', 'sold')) INTO v_res;
  SELECT status::text, current_value INTO v_status, v_val FROM finance.real_estate WHERE id = v_id;
  IF v_status IS DISTINCT FROM 'sold' OR v_val IS DISTINCT FROM 350000 THEN
    RAISE EXCEPTION 'FAIL set_real_estate [sold]: status=% value=%', v_status, v_val;
  END IF;
  RAISE NOTICE 'PASS set_real_estate [status=sold, value stabil]';

  -- TEST 3: negativer Wert -> {ok:false}
  SELECT finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_id, 'current_value', -5)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_real_estate [neg]: erwartet ok=false, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_real_estate [neg value -> ok:false]';

END $$;

ROLLBACK;
