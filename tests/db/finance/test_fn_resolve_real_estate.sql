-- tests/db/finance/test_fn_resolve_real_estate.sql
-- Testet fn_resolve_real_estate: 1 Treffer (id gesetzt), 0 Treffer, >1 Treffer (Ambiguitaet)
BEGIN;

DO $$
DECLARE
  v_res     JSONB;
  v_id1     INT;
  v_id      INT;
  v_count   INT;
BEGIN

  -- Setup: zwei Immobilien gleichen Namens + eine eindeutige
  SELECT finance.fn_create_real_estate('{"name":"__test_re_dup__","current_value":100000}'::jsonb) INTO v_res;
  SELECT finance.fn_create_real_estate('{"name":"__test_re_dup__","current_value":200000}'::jsonb) INTO v_res;
  SELECT finance.fn_create_real_estate('{"name":"__test_re_uniq__","current_value":300000}'::jsonb) INTO v_res;
  v_id1 := (v_res->>'real_estate_id')::int;

  -- TEST 1: eindeutiger Name -> hit_count=1, id gesetzt
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_real_estate('__test_re_uniq__');
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'FAIL resolve_real_estate [unique]: erwartet count=1 id=%, got count=% id=%', v_id1, v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_real_estate [unique: id=%]', v_id;

  -- TEST 2: nicht existent -> hit_count=0, id NULL
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_real_estate('__test_re_none__');
  IF v_count IS DISTINCT FROM 0 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_real_estate [none]: erwartet count=0 id=NULL, got count=% id=%', v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_real_estate [none]';

  -- TEST 3: Duplikat -> hit_count=2, id NULL (Ambiguitaet)
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_real_estate('__test_re_dup__');
  IF v_count IS DISTINCT FROM 2 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_real_estate [dup]: erwartet count=2 id=NULL, got count=% id=%', v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_real_estate [dup: count=2, id=NULL]';

END $$;

ROLLBACK;
