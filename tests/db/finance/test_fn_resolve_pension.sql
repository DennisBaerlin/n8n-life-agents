-- tests/db/finance/test_fn_resolve_pension.sql
-- Testet fn_resolve_pension: 1 Treffer, 0 Treffer, >1 Treffer (Ambiguitaet)
BEGIN;

DO $$
DECLARE
  v_res   JSONB;
  v_id1   INT;
  v_id    INT;
  v_count INT;
BEGIN

  -- Setup
  SELECT finance.fn_create_pension('{"name":"__test_pen_dup__","pension_type":"private"}'::jsonb) INTO v_res;
  SELECT finance.fn_create_pension('{"name":"__test_pen_dup__","pension_type":"ruerup"}'::jsonb) INTO v_res;
  SELECT finance.fn_create_pension('{"name":"__test_pen_uniq__","pension_type":"riester"}'::jsonb) INTO v_res;
  v_id1 := (v_res->>'pension_id')::int;

  -- TEST 1: eindeutig
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_pension('__test_pen_uniq__');
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'FAIL resolve_pension [unique]: erwartet count=1 id=%, got count=% id=%', v_id1, v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_pension [unique: id=%]', v_id;

  -- TEST 2: keiner
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_pension('__test_pen_none__');
  IF v_count IS DISTINCT FROM 0 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_pension [none]: got count=% id=%', v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_pension [none]';

  -- TEST 3: Ambiguitaet
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_pension('__test_pen_dup__');
  IF v_count IS DISTINCT FROM 2 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_pension [dup]: got count=% id=%', v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_pension [dup: count=2, id=NULL]';

END $$;

ROLLBACK;
