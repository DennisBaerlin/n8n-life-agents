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
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__' AND key <> '__first_run__';
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
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__' AND key <> '__first_run__';
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
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__:erika' AND key <> '__first_run__';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [7f] erika-Reconcile raeumte die eigene person-source nicht (%)', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:__test__:lena' AND key <> '__first_run__';
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

-- (9) told_keys: Merker zuerst, gesagte Lage meldet nicht; erster Lauf.
DO $$
DECLARE r jsonb;
BEGIN
  DELETE FROM core.notification_state WHERE source LIKE 'advisor:__test__%' OR source = 'fold:told';

  -- gesagt -> kein Alarm, Merker fired, send=false; Erst-Merker bleibt unverbraucht
  PERFORM core.fn_should_notify('fold:told', 'k1', interval '3 days');
  PERFORM set_config('test.alerts', '[{"metric_key":"m1","told_keys":[{"source":"fold:told","key":"k1"}]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean OR jsonb_array_length(r->'alerts') <> 0 THEN RAISE EXCEPTION 'FAIL [9a told -> kein Alarm]: %', r; END IF;
  IF (SELECT state FROM core.notification_state WHERE source = 'advisor:__test__' AND key = 'm1') <> 'fired' THEN
    RAISE EXCEPTION 'FAIL [9a Merker fired]'; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'advisor:__test__' AND key = '__first_run__') THEN
    RAISE EXCEPTION 'FAIL [9a alle told: Erst-Merker unverbraucht]'; END IF;

  -- abgelaufener Fold-Merker -> Alarm
  DELETE FROM core.notification_state WHERE source = 'advisor:__test__';
  UPDATE core.notification_state SET expires_at = now() - interval '1 minute' WHERE source = 'fold:told' AND key = 'k1';
  r := core.fn_advisor_review_evaluate('__test__');
  IF jsonb_array_length(r->'alerts') <> 1 THEN RAISE EXCEPTION 'FAIL [9b abgelaufen -> Alarm]: %', r; END IF;
  IF (r->>'first_run')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [9b first_run]: %', r; END IF;

  -- latch_key trifft nur ein Element, das andere meldet
  DELETE FROM core.notification_state WHERE source = 'advisor:__test__';
  PERFORM core.fn_should_notify('fold:told', 'res:1', interval '3 days');
  PERFORM set_config('test.alerts', '[{"metric_key":"res","latch_keys":["1","2"],"told_keys":[{"source":"fold:told","key":"res:1","latch_key":"1"}]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF jsonb_array_length(r->'alerts') <> 1 THEN RAISE EXCEPTION 'FAIL [9c anderes Element meldet]: %', r; END IF;
  IF r->'alerts'->0->'_latched' <> '[{"source":"advisor:__test__","key":"res#2"}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [9c nur das nicht gesagte Element frisch]: %', r->'alerts'->0->'_latched'; END IF;
  -- alle Elemente gesagt -> still
  DELETE FROM core.notification_state WHERE source = 'advisor:__test__';
  PERFORM set_config('test.alerts', '[{"metric_key":"res","latch_keys":["1"],"told_keys":[{"source":"fold:told","key":"res:1","latch_key":"1"}]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF jsonb_array_length(r->'alerts') <> 0 THEN RAISE EXCEPTION 'FAIL [9d Element gesagt -> still]: %', r; END IF;

  -- erster Lauf: alle vier, alle Merker; naechster Lauf first_run=false; leerer Lauf verbraucht nichts; Reconcile laesst Erst-Merker
  DELETE FROM core.notification_state WHERE source = 'advisor:__test__';
  PERFORM set_config('test.alerts', '[]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'first_run')::boolean IS NOT FALSE
     OR EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'advisor:__test__') THEN
    RAISE EXCEPTION 'FAIL [9e leerer erster Lauf verbraucht nichts]: %', r; END IF;

  PERFORM set_config('test.alerts', '[{"metric_key":"a"},{"metric_key":"b"},{"metric_key":"c"},{"metric_key":"d"}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF jsonb_array_length(r->'alerts') <> 4 OR (r->>'first_run')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [9f vier + first_run]: %', r; END IF;
  IF (SELECT count(*) FROM core.notification_state WHERE source = 'advisor:__test__' AND state = 'fired') <> 5 THEN
    RAISE EXCEPTION 'FAIL [9f alle Merker + Erst-Merker]'; END IF;

  PERFORM set_config('test.alerts', '[]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'advisor:__test__' AND key = '__first_run__') THEN
    RAISE EXCEPTION 'FAIL [9g Reconcile loescht Erst-Merker nicht]'; END IF;

  PERFORM set_config('test.alerts', '[{"metric_key":"z"}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'first_run')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [9h naechster Lauf first_run=false]: %', r; END IF;
  RAISE NOTICE 'PASS [9] told_keys + erster Lauf';
END $$;

-- Tagesbudget im Waechter
INSERT INTO core.advisors (domain, plan_context, review_fn, package, own_review_cron)
VALUES ('__tb2__', 'x', 'finance.fn__test_advisor_review', '__test__', FALSE), ('__tbo__', 'x', 'finance.fn__test_advisor_review', '__test__', TRUE);
DO $$
DECLARE
  r jsonb; o text; d date := core.fn_today();
  a text := '[{"metric_key":"m1"}]';
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'tb fixture', NULL, 'lazy', E'## f',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__tb_o__','first_name','TB','last_name','O','role','owner','birth_date','1980-01-01','telegram_user_id',7911,'as_of','2026-11-01'),
            jsonb_build_object('person_id','__tb_p__','first_name','TB','last_name','P','role','partner','birth_date','1982-01-01','telegram_user_id',7912,'as_of','2026-11-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
  o := agent.fn_owner_person_id();
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  DELETE FROM core.notification_state WHERE source LIKE 'advisor:__t%';
  PERFORM set_config('test.alerts', a, true);
  -- voll -> deferred, keine Merker, Erst-Merker frei
  PERFORM core.fn_proactive_claim(o, 'x1', 'normal'); PERFORM core.fn_proactive_claim(o, 'x2', 'normal');
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean OR (r->>'deferred')::boolean IS NOT TRUE OR jsonb_array_length(r->'alerts') <> 0 OR (r->>'first_run')::boolean THEN RAISE EXCEPTION 'FAIL [B1]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'advisor:__test__' AND state = 'fired') THEN RAISE EXCEPTION 'FAIL [B1 Merker]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.proactive_deferred WHERE person_id = o AND slot = 'advisor_drift') THEN RAISE EXCEPTION 'FAIL [B1 Altern]'; END IF;
  -- naechster Tag meldet
  UPDATE core.proactive_budget SET day = day - 1;
  r := core.fn_advisor_review_evaluate('__test__');
  IF NOT (r->>'send')::boolean OR (r->>'first_run')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [B2]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.proactive_budget WHERE person_id = o AND day = d AND slot = 'advisor_drift' AND class = 'normal') THEN RAISE EXCEPTION 'FAIL [B2 Slot]'; END IF;
  -- nichts neu (told) -> kein neuer Slot
  DELETE FROM core.proactive_budget;
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean OR EXISTS (SELECT 1 FROM core.proactive_budget) THEN RAISE EXCEPTION 'FAIL [B3]: %', r; END IF;
  -- kein Alarm -> kein Slot
  PERFORM set_config('test.alerts', '[]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF EXISTS (SELECT 1 FROM core.proactive_budget) THEN RAISE EXCEPTION 'FAIL [B4]'; END IF;
  -- deferred reconciled: gesetzter Merker bleibt, wenn der Alert noch da ist und daneben ein neuer wartet
  PERFORM set_config('test.alerts', a, true);
  r := core.fn_advisor_review_evaluate('__test__');
  DELETE FROM core.proactive_budget;
  PERFORM core.fn_proactive_claim(o, 'x1', 'normal'); PERFORM core.fn_proactive_claim(o, 'x2', 'normal');
  PERFORM set_config('test.alerts', '[{"metric_key":"m1"},{"metric_key":"m2"}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'deferred')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [B5]: %', r; END IF;
  IF NOT core.fn_notify_told('advisor:__test__', 'm1') THEN RAISE EXCEPTION 'FAIL [B5 Reconcile raeumte m1]'; END IF;
  -- Told-Key: gesagte Lage belegt keinen Slot
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred; DELETE FROM core.notification_state WHERE source LIKE 'advisor:__t%';
  PERFORM core.fn_should_notify('__ext__', 'k');
  PERFORM set_config('test.alerts', '[{"metric_key":"m3","told_keys":[{"source":"__ext__","key":"k"}]}]', true);
  r := core.fn_advisor_review_evaluate('__test__');
  IF (r->>'send')::boolean OR EXISTS (SELECT 1 FROM core.proactive_budget) THEN RAISE EXCEPTION 'FAIL [B6]: %', r; END IF;
  -- zwei Domains teilen advisor_drift; eigener Cron priority
  DELETE FROM core.proactive_budget; DELETE FROM core.notification_state WHERE source LIKE 'advisor:__t%';
  PERFORM set_config('test.alerts', a, true);
  PERFORM core.fn_advisor_review_evaluate('__test__'); PERFORM core.fn_advisor_review_evaluate('__tb2__');
  IF (SELECT count(*) FROM core.proactive_budget) <> 1 THEN RAISE EXCEPTION 'FAIL [B7 geteilt]'; END IF;
  PERFORM core.fn_proactive_claim(o, 'x9', 'normal');
  r := core.fn_advisor_review_evaluate('__tbo__');
  IF NOT (r->>'send')::boolean OR NOT EXISTS (SELECT 1 FROM core.proactive_budget WHERE slot = 'advisor:__tbo__' AND class = 'priority') THEN RAISE EXCEPTION 'FAIL [B8 priority]: %', r; END IF;
  -- Lauf mit Partner-pid belegt den Slot des Owners
  DELETE FROM core.proactive_budget;
  r := core.fn_advisor_review_evaluate('__test__', '__tb_p__');
  IF NOT EXISTS (SELECT 1 FROM core.proactive_budget WHERE person_id = o) OR EXISTS (SELECT 1 FROM core.proactive_budget WHERE person_id <> o) THEN
    RAISE EXCEPTION 'FAIL [B9 Owner-Slot]'; END IF;
  RAISE NOTICE 'PASS test_fn_advisor_review_evaluate Budget';
END $$;

ROLLBACK;
