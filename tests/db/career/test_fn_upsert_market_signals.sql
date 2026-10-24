-- tests/db/career/test_fn_upsert_market_signals.sql
-- career.fn_upsert_market_signals: atomarer datierter Posting-Count-Cache-Upsert (still-guarded, kein RAISE).
-- scope_key via fn_market_scope_key aus rohen Feldern; ON CONFLICT (scope_key, as_of) = Tages-Upsert.
BEGIN;
DO $$
DECLARE
  v_res  jsonb;
  v_pkey text := career.fn_market_scope_key('postings','Scrum Master','Hamburg');
BEGIN
  -- ---------- TEST 1: kein signals-Array -> ok:false (korrigierbar, kein RAISE) ----------
  v_res := career.fn_upsert_market_signals('{}'::jsonb);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 no array -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS [1] kein signals-Array -> ok:false';

  -- ---------- TEST 2: postings -> Zeile mit korrektem scope_key + count ----------
  v_res := career.fn_upsert_market_signals(jsonb_build_object(
    'as_of', to_char(CURRENT_DATE,'YYYY-MM-DD'), 'source','bundesagentur',
    'signals', jsonb_build_array(
      jsonb_build_object('kind','postings','primary','Scrum Master','secondary','Hamburg','postings_count',120))));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'upserted')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [2 upserted 1]: %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM career.market_signals WHERE scope_key = v_pkey AND postings_count = 120) THEN
    RAISE EXCEPTION 'FAIL [2 postings row]'; END IF;
  RAISE NOTICE 'PASS [2] postings -> Zeile via fn_market_scope_key';

  -- ---------- TEST 3: idempotenter Tages-Upsert (gleicher scope+as_of -> UPDATE, kein Dup) ----------
  v_res := career.fn_upsert_market_signals(jsonb_build_object(
    'signals', jsonb_build_array(jsonb_build_object('kind','postings','primary','Scrum Master','secondary','Hamburg','postings_count',130))));
  IF (SELECT count(*) FROM career.market_signals WHERE scope_key = v_pkey AND as_of = CURRENT_DATE) <> 1 THEN
    RAISE EXCEPTION 'FAIL [3 kein Dup]'; END IF;
  IF (SELECT postings_count FROM career.market_signals WHERE scope_key = v_pkey AND as_of = CURRENT_DATE) <> 130 THEN
    RAISE EXCEPTION 'FAIL [3 count aktualisiert]'; END IF;
  RAISE NOTICE 'PASS [3] idempotenter Tages-Upsert (ON CONFLICT UPDATE)';

  -- ---------- TEST 4: nicht-ganzzahliger count -> still NULL, kein RAISE (EARS-7) ----------
  v_res := career.fn_upsert_market_signals(jsonb_build_object(
    'signals', jsonb_build_array(jsonb_build_object('kind','postings','primary','Data Scientist','secondary','Berlin','postings_count','n/a'))));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4 ok trotz junk]: %', v_res; END IF;
  IF (SELECT postings_count FROM career.market_signals WHERE scope_key = career.fn_market_scope_key('postings','Data Scientist','Berlin')) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [4 nicht-ganzzahlig -> NULL]'; END IF;
  RAISE NOTICE 'PASS [4] nicht-ganzzahliger count -> still NULL, kein RAISE';

  -- ---------- TEST 5: Eintrag ohne kind/primary -> skip (kein leerer scope_key) ----------
  v_res := career.fn_upsert_market_signals(jsonb_build_object(
    'signals', jsonb_build_array(
      jsonb_build_object('kind','','primary','x','postings_count',5),
      jsonb_build_object('kind','postings','primary','','postings_count',5))));
  IF (v_res->>'upserted')::int <> 0 THEN RAISE EXCEPTION 'FAIL [5 skip ohne kind/primary]: %', v_res; END IF;
  RAISE NOTICE 'PASS [5] Eintrag ohne kind/primary -> skip';

  RAISE NOTICE 'PASS test_fn_upsert_market_signals';
END $$;
ROLLBACK;
