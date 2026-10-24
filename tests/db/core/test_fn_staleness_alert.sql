-- tests/db/core/test_fn_staleness_alert.sql
-- core.fn_staleness_alert — der geteilte Staleness-Alarm-Form-Helfer der Paket-Reviewer (fn_advisor_review).
-- Kapselt die 4x duplizierte Schwellen-Entscheidung + die {kind:'staleness'}-Alarm-jsonb-Form. Reine
-- IMMUTABLE-Arithmetik (kein Read). Rueckgabe = jsonb-ARRAY: [] (nicht stale) | [alarm] (stale), damit
-- `v_alerts || fn(...)` bedingungslos sicher ist.
--   (1) stale (age > threshold) -> [alarm] mit korrekten Feldern + drift, msg woertlich durchgereicht
--   (2) nicht-stale (age < threshold) -> []
--   (3) Grenze exakt (age = threshold) -> [] (strikt >)
--   (4) NULL age -> []
--   (5) numeric-Aufruf bindet (Regression gegen den integer-Signatur-Blocker) + integer bindet implizit
--   (6) Geschwister-Schutz: bestehendes Array || fn(nicht-stale) verliert kein Element (array || [])
--   (7) kein 'text'-Key mehr (Struktur statt deutschem Text, Textkatalog Phase C)
--   (8) die alte Text-Signatur (text,text,numeric,numeric,text) ist gedroppt (core:V030)
BEGIN;

DO $$
DECLARE
  v_res   jsonb;
  v_a     jsonb;
  v_age   numeric;
  v_days  numeric;
  v_merged jsonb;
  v_msg   jsonb := jsonb_build_array(jsonb_build_object('kind','tpl','value','finance.advisor.plan_stale',
                                                        'params', jsonb_build_object('days', 400)));
BEGIN
  -- (1) stale: age 400 > threshold 365 -> [alarm]
  v_res := core.fn_staleness_alert('plan_staleness', 'plan_staleness', 400, 365, v_msg);
  IF jsonb_typeof(v_res) <> 'array' THEN
    RAISE EXCEPTION 'FAIL [1]: Rueckgabe ist kein jsonb-Array (=%)', v_res; END IF;
  IF jsonb_array_length(v_res) <> 1 THEN
    RAISE EXCEPTION 'FAIL [1]: stale -> erwartet Array-Laenge 1 (=%)', v_res; END IF;
  v_a := v_res->0;
  IF v_a->>'metric_key' <> 'plan_staleness' THEN RAISE EXCEPTION 'FAIL [1]: metric_key falsch (=%)', v_a; END IF;
  IF v_a->>'kind' <> 'staleness'          THEN RAISE EXCEPTION 'FAIL [1]: kind <> staleness (=%)', v_a; END IF;
  IF v_a->>'label' <> 'plan_staleness'    THEN RAISE EXCEPTION 'FAIL [1]: label falsch (=%)', v_a; END IF;
  IF (v_a->>'value')::numeric  <> 400     THEN RAISE EXCEPTION 'FAIL [1]: value <> 400 (=%)', v_a; END IF;
  IF (v_a->>'target')::numeric <> 365     THEN RAISE EXCEPTION 'FAIL [1]: target <> 365 (=%)', v_a; END IF;
  IF (v_a->>'drift')::numeric  <> 35      THEN RAISE EXCEPTION 'FAIL [1]: drift <> 35 (=%)', v_a; END IF;
  IF v_a->'msg' <> v_msg                  THEN RAISE EXCEPTION 'FAIL [1]: msg nicht durchgereicht (=%)', v_a; END IF;
  RAISE NOTICE 'PASS [1] stale -> [alarm] mit korrekten Feldern (metric_key/kind/label/value/target/drift/msg)';

  -- (2) nicht-stale: age 100 < threshold 365 -> []
  v_res := core.fn_staleness_alert('plan_staleness', 'l', 100, 365, v_msg);
  IF v_res <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [2]: age<threshold -> erwartet [] (=%)', v_res; END IF;
  RAISE NOTICE 'PASS [2] nicht-stale -> []';

  -- (3) Grenze exakt: age = threshold -> [] (Vergleich ist strikt >)
  v_res := core.fn_staleness_alert('plan_staleness', 'l', 365, 365, v_msg);
  IF v_res <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [3]: age=threshold -> erwartet [] (strikt >) (=%)', v_res; END IF;
  RAISE NOTICE 'PASS [3] age=threshold -> [] (strikt >)';

  -- (4) NULL age -> []
  v_res := core.fn_staleness_alert('plan_staleness', 'l', NULL, 365, v_msg);
  IF v_res <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [4]: NULL age -> erwartet [] (=%)', v_res; END IF;
  RAISE NOTICE 'PASS [4] NULL age -> []';

  -- (5) numeric-Variablen binden (Regression gegen den integer-Signatur-Blocker: finance/career uebergeben
  -- NUMERIC) + integer-Ausdruck bindet implizit (estate uebergibt r.age_days = date - date = integer)
  v_age := 400; v_days := 365;
  v_res := core.fn_staleness_alert('k', 'l', v_age, v_days, v_msg);
  IF jsonb_array_length(v_res) <> 1 THEN RAISE EXCEPTION 'FAIL [5a]: numeric-Aufruf bindet nicht (=%)', v_res; END IF;
  v_res := core.fn_staleness_alert('k', 'l', (400)::integer, (365)::integer, v_msg);
  IF jsonb_array_length(v_res) <> 1 THEN RAISE EXCEPTION 'FAIL [5b]: integer-Aufruf bindet nicht (=%)', v_res; END IF;
  RAISE NOTICE 'PASS [5] numeric- UND integer-Argumente binden (Signatur-Regression)';

  -- (6) Geschwister-Schutz: ein bestehendes Alert-Array || fn(nicht-stale) darf das Geschwister NICHT loeschen
  -- (die array || []-Garantie, die die frueher geplante array || NULL-Falle ersetzt)
  v_merged := '[{"metric_key":"sibling"}]'::jsonb || core.fn_staleness_alert('k', 'l', 10, 365, v_msg);
  IF jsonb_array_length(v_merged) <> 1 OR v_merged->0->>'metric_key' <> 'sibling' THEN
    RAISE EXCEPTION 'FAIL [6]: nicht-stale-Aufruf hat das Geschwister-Element zerstoert (=%)', v_merged; END IF;
  v_merged := '[{"metric_key":"sibling"}]'::jsonb || core.fn_staleness_alert('k', 'l', 400, 365, v_msg);
  IF jsonb_array_length(v_merged) <> 2 THEN
    RAISE EXCEPTION 'FAIL [6]: stale-Aufruf haengt nicht sauber an (erwartet 2 Elemente) (=%)', v_merged; END IF;
  RAISE NOTICE 'PASS [6] Geschwister-Schutz: array || fn(...) bedingungslos sicher (kein NULL-Verlust)';

  -- (7) Struktur statt Text: kein 'text'-Key im Alarm
  v_res := core.fn_staleness_alert('plan_staleness', 'plan_staleness', 400, 365, v_msg);
  IF v_res->0 ? 'text' THEN RAISE EXCEPTION 'FAIL [7]: Alarm traegt noch einen text-Key (=%)', v_res; END IF;
  RAISE NOTICE 'PASS [7] kein text-Key (msg statt text)';

  -- (8) die alte Text-Signatur ist weg (core:V030)
  IF to_regprocedure('core.fn_staleness_alert(text,text,numeric,numeric,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [8]: alte Text-Signatur existiert noch'; END IF;
  RAISE NOTICE 'PASS [8] alte Text-Signatur gedroppt';

  RAISE NOTICE 'ALL PASS: core.fn_staleness_alert';
END $$;

ROLLBACK;
