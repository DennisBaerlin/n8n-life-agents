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
  SELECT finance.fn_create_pension('{"name":"__test_pen_dup_b__","pension_type":"ruerup"}'::jsonb) INTO v_res;
  -- Bestands-Dublette (sql.md: legitim, die create-fn lehnt eine neue ab) -> per UPDATE nachgestellt
  UPDATE finance.pension SET name = '__test_pen_dup__' WHERE name = '__test_pen_dup_b__';
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

  -- TEST 4: p_active_only NULL = aktive zuerst, ohne aktiven Treffer alle (die Aendern-Werkzeuge finden so auch Nicht-Aktives)
  UPDATE finance.pension SET status = 'paused' WHERE name = '__test_pen_uniq__';
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_pension('__test_pen_uniq__');
  IF v_count IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL resolve_pension [Standard nur aktive]: count=%', v_count; END IF;
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_pension('__test_pen_uniq__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.pension x WHERE x.name = '__test_pen_uniq__') THEN
    RAISE EXCEPTION 'FAIL resolve_pension [NULL findet Nicht-Aktives]: count=% id=%', v_count, v_id; END IF;
  -- zwei gleichnamige, eine nicht aktiv: NULL nimmt die aktive, FALSE meldet beide
  UPDATE finance.pension SET status = 'paused' WHERE id = (SELECT min(x.id) FROM finance.pension x WHERE x.name = '__test_pen_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_pension('__test_pen_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT max(x.id) FROM finance.pension x WHERE x.name = '__test_pen_dup__') THEN
    RAISE EXCEPTION 'FAIL resolve_pension [NULL bevorzugt die aktive]: count=% id=%', v_count, v_id; END IF;
  SELECT hit_count INTO v_count FROM finance.fn_resolve_pension('__test_pen_dup__', FALSE);
  IF v_count IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL resolve_pension [FALSE meldet beide]: count=%', v_count; END IF;
  -- "aktive zuerst" gilt ueber beide Treffer-Stufen: die aktive mit anderer Gross-/Kleinschreibung schlaegt die nicht aktive mit exaktem Namen
  UPDATE finance.pension SET name = '__TEST_PEN_DUP__' WHERE id = (SELECT max(x.id) FROM finance.pension x WHERE x.name = '__test_pen_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_pension('__test_pen_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.pension x WHERE x.name = '__TEST_PEN_DUP__') THEN
    RAISE EXCEPTION 'FAIL resolve_pension [NULL: aktive (andere Schreibweise) vor nicht aktiver (exakt)]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_pension [NULL: aktive zuerst, sonst alle]';

END $$;

ROLLBACK;
