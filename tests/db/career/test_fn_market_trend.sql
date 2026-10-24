-- tests/db/career/test_fn_market_trend.sql
-- career.fn_market_trend: deterministischer Stellen-Nachfrage-Trend der primaeren Ziel-Rolle (RAISE-frei).
-- liest career.market_signals (postings); Trend = Delta vs vorheriger Messung desselben scope_key.
BEGIN;
DO $$
DECLARE
  v_plan jsonb;
  v_res  jsonb;
  v_pkey text := career.fn_market_scope_key('postings','Scrum Master','Hamburg');
BEGIN
  v_plan := jsonb_build_object(
    'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master')),
    'target_locations', jsonb_build_array('Hamburg'));

  -- ---------- TEST 1: kein Cache -> NULL, kein RAISE ----------
  IF career.fn_market_trend(v_plan) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1 kein Cache -> NULL]'; END IF;
  RAISE NOTICE 'PASS [1] kein Cache -> NULL';

  -- zwei Posting-Messungen (heute 120, vor 7 Tagen 100)
  INSERT INTO career.market_signals (scope_key, as_of, postings_count) VALUES (v_pkey, CURRENT_DATE - 7, 100);
  INSERT INTO career.market_signals (scope_key, as_of, postings_count) VALUES (v_pkey, CURRENT_DATE, 120);

  -- ---------- TEST 2: count + Trend up ----------
  v_res := career.fn_market_trend(v_plan);
  IF (v_res->>'count')::int <> 120 OR (v_res->>'prev_count')::int <> 100 THEN RAISE EXCEPTION 'FAIL [2 count/prev]: %', v_res; END IF;
  IF (v_res->>'trend_pct')::numeric <> 20.0 OR v_res->>'direction' <> 'up' THEN RAISE EXCEPTION 'FAIL [2 trend up]: %', v_res; END IF;
  IF v_res->>'role' <> 'Scrum Master' OR v_res->>'location' <> 'Hamburg' THEN RAISE EXCEPTION 'FAIL [2 role/location]: %', v_res; END IF;
  RAISE NOTICE 'PASS [2] count 120 / prev 100 / Trend +20 up';

  -- ---------- TEST 3: Trend braucht 2 Messungen (nur 1 row -> trend null, flat) ----------
  DELETE FROM career.market_signals WHERE scope_key = v_pkey AND as_of = CURRENT_DATE - 7;
  v_res := career.fn_market_trend(v_plan);
  IF (v_res->>'count')::int <> 120 THEN RAISE EXCEPTION 'FAIL [3 count bleibt]: %', v_res; END IF;
  IF v_res->>'trend_pct' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 trend null bei 1 Messung]: %', v_res; END IF;
  IF v_res->>'direction' <> 'flat' THEN RAISE EXCEPTION 'FAIL [3 direction flat]: %', v_res; END IF;
  RAISE NOTICE 'PASS [3] nur 1 Messung -> kein Trend (trend_pct null, direction flat)';

  -- ---------- TEST 4: anderer Ort -> kein scope-Treffer -> NULL ----------
  IF career.fn_market_trend(jsonb_build_object(
       'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master')),
       'target_locations', jsonb_build_array('Muenchen'))) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [4 anderer Ort -> NULL]'; END IF;
  RAISE NOTICE 'PASS [4] anderer Ort -> kein scope-Treffer -> NULL';

  -- ---------- TEST 5: kein Plan/keine Rolle/NULL -> NULL, kein RAISE ----------
  IF career.fn_market_trend('{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 empty plan]'; END IF;
  IF career.fn_market_trend(NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 NULL]'; END IF;
  IF career.fn_market_trend(jsonb_build_object('target_roles', jsonb_build_array(jsonb_build_object('title','   ')))) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [5 leerer Titel]'; END IF;
  RAISE NOTICE 'PASS [5] kein Plan/Rolle/NULL -> NULL, kein RAISE';

  RAISE NOTICE 'PASS test_fn_market_trend';
END $$;
ROLLBACK;
