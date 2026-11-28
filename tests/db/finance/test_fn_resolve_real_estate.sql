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
  SELECT finance.fn_create_real_estate('{"name":"__test_re_dup_b__","current_value":200000}'::jsonb) INTO v_res;
  -- Bestands-Dublette (sql.md: legitim, die create-fn lehnt eine neue ab) -> per UPDATE nachgestellt
  UPDATE finance.real_estate SET name = '__test_re_dup__' WHERE name = '__test_re_dup_b__';
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

  -- TEST 4: p_active_only NULL = aktive zuerst, ohne aktiven Treffer alle (die Aendern-Werkzeuge finden so auch Nicht-Aktives)
  UPDATE finance.real_estate SET status = 'sold' WHERE name = '__test_re_uniq__';
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_real_estate('__test_re_uniq__');
  IF v_count IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL resolve_real_estate [Standard nur aktive]: count=%', v_count; END IF;
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_real_estate('__test_re_uniq__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.real_estate x WHERE x.name = '__test_re_uniq__') THEN
    RAISE EXCEPTION 'FAIL resolve_real_estate [NULL findet Nicht-Aktives]: count=% id=%', v_count, v_id; END IF;
  -- zwei gleichnamige, eine nicht aktiv: NULL nimmt die aktive, FALSE meldet beide
  UPDATE finance.real_estate SET status = 'sold' WHERE id = (SELECT min(x.id) FROM finance.real_estate x WHERE x.name = '__test_re_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_real_estate('__test_re_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT max(x.id) FROM finance.real_estate x WHERE x.name = '__test_re_dup__') THEN
    RAISE EXCEPTION 'FAIL resolve_real_estate [NULL bevorzugt die aktive]: count=% id=%', v_count, v_id; END IF;
  SELECT hit_count INTO v_count FROM finance.fn_resolve_real_estate('__test_re_dup__', FALSE);
  IF v_count IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL resolve_real_estate [FALSE meldet beide]: count=%', v_count; END IF;
  -- "aktive zuerst" gilt ueber beide Treffer-Stufen: die aktive mit anderer Gross-/Kleinschreibung schlaegt die nicht aktive mit exaktem Namen
  UPDATE finance.real_estate SET name = '__TEST_RE_DUP__' WHERE id = (SELECT max(x.id) FROM finance.real_estate x WHERE x.name = '__test_re_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_real_estate('__test_re_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.real_estate x WHERE x.name = '__TEST_RE_DUP__') THEN
    RAISE EXCEPTION 'FAIL resolve_real_estate [NULL: aktive (andere Schreibweise) vor nicht aktiver (exakt)]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_real_estate [NULL: aktive zuerst, sonst alle]';

END $$;

ROLLBACK;
