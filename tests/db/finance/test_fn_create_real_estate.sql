-- tests/db/finance/test_fn_create_real_estate.sql
-- Testet fn_create_real_estate: einfacher INSERT (als fn_* für Konsistenz)
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_id     INT;
BEGIN

  -- TEST 1: Minimal (nur name)
  SELECT finance.fn_create_real_estate(
    '{"name":"__test_immo__"}'::jsonb
  ) INTO v_result;

  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR NOT (v_result ? 'real_estate_id') THEN
    RAISE EXCEPTION 'FAIL fn_create_real_estate [1]: erwartet ok:true + real_estate_id, got %', v_result;
  END IF;
  v_id := (v_result->>'real_estate_id')::int;

  -- WS-4: ohne owner_person_id -> NULL = Haushalt (kein Freitext-Inhaber mehr).
  IF NOT EXISTS (
    SELECT 1 FROM finance.real_estate
    WHERE id = v_id AND name = '__test_immo__' AND status = 'active' AND owner_person_id IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_real_estate [1]: Row nicht korrekt angelegt / owner_person_id nicht NULL (id=%)', v_id;
  END IF;

  RAISE NOTICE 'PASS fn_create_real_estate [1 minimal, owner_person_id NULL=Haushalt]: id=%', v_id;

  -- WS-4 Fixture: eine projizierte Person (direkt in agent.persons; FK-Ziel fuer owner_person_id).
  INSERT INTO agent.persons (person_id, full_name, role)
  VALUES ('__test_re_owner', 'Test Eigentuemer', 'owner')
  ON CONFLICT (person_id) DO NOTHING;

  -- TEST 2: Mit Wert + typisiertem Eigentuemer (owner_person_id-Slug, im Tool aufgeloest).
  SELECT finance.fn_create_real_estate(
    '{"name":"__test_immo2__","current_value":"350000","owner_person_id":"__test_re_owner","value_updated_at":"2024-06-01"}'::jsonb
  ) INTO v_result;

  v_id := (v_result->>'real_estate_id')::int;

  IF NOT EXISTS (
    SELECT 1 FROM finance.real_estate
    WHERE id = v_id AND current_value = 350000 AND owner_person_id = '__test_re_owner'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_real_estate [2]: Wert/owner_person_id nicht gesetzt (id=%)', v_id;
  END IF;

  RAISE NOTICE 'PASS fn_create_real_estate [2 mit Wert + owner_person_id]: id=%, value=350000', v_id;

END $$;

ROLLBACK;
