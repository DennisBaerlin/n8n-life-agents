-- tests/db/core/test_fn_advisor_review_evaluate.sql
-- WS2: der generische Core-Eval-/Latch-Wrapper core.fn_advisor_review_evaluate. Isoliert die LATCH-
-- Logik von der finance-Review-fn ueber einen STUB-Reviewer, dessen alerts via GUC test.alerts gesteuert
-- werden (db_test hat kein seed_data -> die core.advisors-Zeile + der Stub werden im Test angelegt).
-- (Phase Notify: der Latch lebt jetzt in der GETEILTEN core.notification_state, source='advisor:'||domain,
--  state 'fired' statt 'breached'.)
--   (1) Erst-Breach -> send=true + state='fired'
--   (2) gleicher Breach erneut -> send=false (still, Latch haelt)
--   (3) wieder im Band (leeres alerts) -> Reconcile raeumt die Zeile (Re-Arm)
--   (4) Re-Breach -> send=true (Latch hat re-armed)
--   (5) Reconcile-GC: A+B breachen -> beide Zeilen; dann nur A -> B-Zeile geloescht, A bleibt
--   (6) unbekannte Domain -> ok=false
BEGIN;

-- Stub-Reviewer: liefert das per GUC gesetzte alerts-Array (Default leer); digest leer.
-- P2a: uniform 3-arg (p_domain, p_person_id, p_obs) — der Wrapper dispatcht 3-arg; der Stub ignoriert person_id.
CREATE OR REPLACE FUNCTION finance.fn__test_advisor_review(p_domain text, p_person_id text, p_obs jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'alerts', COALESCE(NULLIF(current_setting('test.alerts', true), ''), '[]')::jsonb,
        'digest', '{}'::jsonb);
$$;

INSERT INTO core.advisors (domain, plan_context, review_fn, package)
VALUES ('__test__', 'x', 'finance.fn__test_advisor_review', '__test__');

DO $$
DECLARE
  r       jsonb;
  v_cnt   int;
  alert_a text := '[{"metric_key":"alloc:sp500","kind":"alloc","value":80,"target":85,"drift":5}]';
  alert_b text := '[{"metric_key":"emergency_reserve","kind":"emergency_reserve","value":1000,"target":20000,"drift":19000}]';
  alert_ab text := '[{"metric_key":"alloc:sp500","kind":"alloc","value":80,"target":85,"drift":5},'
                || '{"metric_key":"emergency_reserve","kind":"emergency_reserve","value":1000,"target":20000,"drift":19000}]';
BEGIN
  -- (1) Erst-Breach
  PERFORM set_config('test.alerts', alert_a, true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF NOT (r->>'send')::boolean OR jsonb_array_length(r->'alerts') <> 1 THEN
    RAISE EXCEPTION 'FAIL [1]: Erst-Breach send=% alerts=%', r->>'send', r->'alerts';
  END IF;
  IF (SELECT state FROM core.notification_state WHERE source='advisor:__test__' AND key='alloc:sp500')
       IS DISTINCT FROM 'fired' THEN
    RAISE EXCEPTION 'FAIL [1b]: Latch-Zeile advisor:__test__/alloc:sp500 nicht fired'; END IF;
  RAISE NOTICE 'PASS [Erst-Breach -> send + state=fired]';

  -- (2) gleicher Breach erneut -> still
  PERFORM set_config('test.alerts', alert_a, true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [2]: Wiederhol-Breach send=true (Latch haelt nicht)'; END IF;
  RAISE NOTICE 'PASS [Wiederhol-Breach -> still]';

  -- (3) wieder im Band -> Reconcile raeumt
  PERFORM set_config('test.alerts', '[]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [3]: in-band send=true'; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [3b]: stale State-Zeile nicht geraeumt (%)', v_cnt; END IF;
  RAISE NOTICE 'PASS [wieder im Band -> Reconcile raeumt + Re-Arm]';

  -- (4) Re-Breach nach Re-Arm -> send
  PERFORM set_config('test.alerts', alert_a, true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF NOT (r->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [4]: Re-Breach send=false (Re-Arm griff nicht)'; END IF;
  RAISE NOTICE 'PASS [Re-Breach nach Re-Arm -> send]';

  -- (5) Reconcile-GC: A+B -> beide; dann nur A -> B weg, A bleibt
  PERFORM set_config('test.alerts', alert_ab, true);
  PERFORM core.fn_advisor_review_evaluate('__test__');
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__';
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [5a]: A+B nicht beide gelatcht (%)', v_cnt; END IF;
  PERFORM set_config('test.alerts', alert_a, true);
  PERFORM core.fn_advisor_review_evaluate('__test__');
  SELECT count(*) INTO v_cnt FROM core.notification_state
    WHERE source='advisor:__test__' AND key='emergency_reserve';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [5b]: stale B-Key nicht geGC-t'; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state
    WHERE source='advisor:__test__' AND key='alloc:sp500';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [5c]: A-Key faelschlich geloescht'; END IF;
  RAISE NOTICE 'PASS [Reconcile-GC: stale Key geraeumt, aktiver bleibt]';

  -- (6) unbekannte Domain -> ok=false
  r := core.fn_advisor_review_evaluate('__nope__');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [6]: unbekannte Domain ok=true'; END IF;
  RAISE NOTICE 'PASS [unbekannte Domain -> ok=false, graceful]';

  -- (7) P2a Person-Faecherung: zwei Personen latchen UNABHAENGIG (source 'advisor:__test__:<pid>'); der
  -- 1-Arg-Call (person NULL, Tests 1-6) bleibt byte-gleich 'advisor:__test__'. M2: Reconcile-GC person-isoliert.
  PERFORM set_config('test.alerts', alert_a, true);
  r := core.fn_advisor_review_evaluate('__test__', 'erika');
  IF NOT (r->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [7a] erika Erst-Breach send=false'; END IF;
  r := core.fn_advisor_review_evaluate('__test__', 'lena');   -- eigener Latch -> send trotz erikas fired-Zeile
  IF NOT (r->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [7b] lena Erst-Breach send=false (Latch nicht person-getrennt)'; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__:erika' AND key='alloc:sp500';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [7c] erika person-source-Zeile fehlt (%)', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__:lena' AND key='alloc:sp500';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [7d] lena person-source-Zeile fehlt (%)', v_cnt; END IF;
  r := core.fn_advisor_review_evaluate('__test__', 'erika');  -- still (eigener Latch haelt)
  IF (r->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [7e] erika Wiederhol-Breach send=true'; END IF;
  -- M2: erika wieder im Band -> Reconcile raeumt NUR erikas person-source, lena bleibt
  PERFORM set_config('test.alerts', '[]', true);
  PERFORM core.fn_advisor_review_evaluate('__test__', 'erika');
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__:erika';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [7f] erika-Reconcile raeumte die eigene person-source nicht (%)', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__:lena';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [7g] lena-Zeile faelschlich vom erika-Reconcile geraeumt (%)', v_cnt; END IF;
  RAISE NOTICE 'PASS [7] Person-Faecherung: getrennte Latches je person-source + Reconcile-GC person-isoliert (M2)';
END $$;

-- (8) Roter Faden latch_keys (mit e2 abgestimmt): ein Mengen-Alarm (z. B. data_quality "Positionen ohne Anlageklasse")
--     latcht je Element (metric_key#k) -> NEU, sobald ein Element neu ist; gleiche Menge still; verschwundene Elemente
--     re-armt der Reconcile; leeres latch_keys = Alt-Verhalten (metric_key).
DO $$
DECLARE r jsonb; v_cnt int;
BEGIN
  DELETE FROM core.notification_state WHERE source = 'advisor:__test__';
  PERFORM set_config('test.alerts', '[{"metric_key":"data_quality","kind":"dq","latch_keys":["11","12"]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [8a erste Menge -> send]: %', r; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source = 'advisor:__test__' AND key IN ('data_quality#11', 'data_quality#12');
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [8a Latch je Element erwartet, % Zeilen]', v_cnt; END IF;

  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8b gleiche Menge -> still]: %', r; END IF;

  PERFORM set_config('test.alerts', '[{"metric_key":"data_quality","kind":"dq","latch_keys":["11","12","13"]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean IS NOT TRUE OR jsonb_array_length(r->'alerts') <> 1 THEN
    RAISE EXCEPTION 'FAIL [8c neues Element -> send (ein Alert)]: %', r; END IF;

  PERFORM set_config('test.alerts', '[{"metric_key":"data_quality","kind":"dq","latch_keys":["13"]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8d Element weg -> still]: %', r; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source = 'advisor:__test__' AND key = 'data_quality#11';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [8d verschwundenes Element re-armt (Zeile weg)]'; END IF;

  PERFORM set_config('test.alerts', '[{"metric_key":"data_quality","kind":"dq","latch_keys":["13","11"]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [8e Wiederkehr -> send]: %', r; END IF;

  PERFORM set_config('test.alerts', '[{"metric_key":"data_quality","kind":"dq","latch_keys":[]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM core.notification_state
       WHERE source = 'advisor:__test__' AND key = 'data_quality') THEN
    RAISE EXCEPTION 'FAIL [8f leeres latch_keys = metric_key-Latch]: %', r; END IF;
  RAISE NOTICE 'PASS [8] latch_keys: je Element gelatcht, neues Element meldet, gleiche Menge still';
END $$;

ROLLBACK;
