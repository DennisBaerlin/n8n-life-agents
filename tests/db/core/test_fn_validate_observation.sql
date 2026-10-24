-- tests/db/core/test_fn_validate_observation.sql
-- Testet fn_validate_observation: die geteilte Validierungs-Kaskade (Stufen 2-4) fuer
-- beschaffte Werte — genutzt von fn_monitor_evaluate UND dem Probe-Pfad der Tools.
-- Signatur (positional, fn-intern wie fn_add_recurring_payment):
--   fn_validate_observation(p_obs jsonb, p_method text, p_expected_unit text,
--                           p_min numeric, p_max numeric, p_jump_pct numeric, p_last numeric)
--   -> normalisierte Observation {ok, value, unit, as_of, source_url, reason}
-- Kaskade: input ok=false durchreichen -> numerischer value -> Unit-Echo (nur web_search +
-- expected_unit gesetzt; case-/trim-tolerant) -> Bounds -> Jump-Guard (nur wenn gesetzt + last).
BEGIN;

DO $$
DECLARE
  v JSONB;
BEGIN

  -- TEST 1: input ok=false wird durchgereicht (Grund bleibt erhalten)
  v := agent.fn_validate_observation(
    '{"ok": false, "reason": "cannot determine: sources conflict"}'::jsonb,
    'web_search', 'USD', NULL, NULL, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT LIKE '%sources conflict%' THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [pass-through]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_validate_observation [ok=false durchgereicht]';

  -- TEST 2: ok=true aber kein numerischer value -> dirty
  v := agent.fn_validate_observation(
    '{"ok": true, "value": null, "unit": "USD"}'::jsonb,
    'web_search', 'USD', NULL, NULL, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [no value]: erwartet ok=false, got %', v;
  END IF;
  v := agent.fn_validate_observation(
    '{"ok": true, "value": "ca. 4000", "unit": "USD"}'::jsonb,
    'web_search', 'USD', NULL, NULL, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [non-numeric]: erwartet ok=false, got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_validate_observation [kein/nicht-numerischer Wert -> dirty]';

  -- TEST 3: Unit-Echo (web_search): Mismatch -> dirty; case-/trim-tolerant -> clean
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 4188.5, "unit": "EUR/oz"}'::jsonb,
    'web_search', 'USD/oz', NULL, NULL, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%unit%' THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [unit mismatch]: got %', v;
  END IF;
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 4188.5, "unit": " usd/OZ "}'::jsonb,
    'web_search', 'USD/oz', NULL, NULL, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [unit tolerant]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_validate_observation [Unit-Echo: Mismatch dirty, tolerant clean]';

  -- TEST 4: Unit-Check gilt NICHT fuer sql/fx (kein Echo vorhanden; expected_unit = Render-Label)
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 5234.12}'::jsonb,
    'sql', 'EUR', NULL, NULL, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [sql ohne unit]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_validate_observation [sql: kein Unit-Echo noetig]';

  -- TEST 5: statische Bounds — out of range dirty, in range clean
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 31.4, "unit": "USD/oz"}'::jsonb,
    'web_search', 'USD/oz', 1000, 10000, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%bound%' THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [below min]: got %', v;
  END IF;
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 4188.5, "unit": "USD/oz"}'::jsonb,
    'web_search', 'USD/oz', 1000, 10000, NULL, NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [in range]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_validate_observation [Bounds]';

  -- TEST 6: Jump-Guard — nur wenn max_jump_pct gesetzt UND letzter sauberer Wert existiert
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 200}'::jsonb,
    'fx_rate', NULL, NULL, NULL, 50, 100);   -- +100% > 50% -> dirty
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%jump%' THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [jump]: got %', v;
  END IF;
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 130}'::jsonb,
    'fx_rate', NULL, NULL, NULL, 50, 100);   -- +30% <= 50% -> clean
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [jump ok]: got %', v;
  END IF;
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 200}'::jsonb,
    'fx_rate', NULL, NULL, NULL, NULL, 100); -- Guard aus (NULL) -> clean
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [jump disabled]: got %', v;
  END IF;
  v := agent.fn_validate_observation(
    '{"ok": true, "value": 200}'::jsonb,
    'fx_rate', NULL, NULL, NULL, 50, NULL);  -- kein last_value (erster Wert) -> clean
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_validate_observation [jump ohne last]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_validate_observation [Jump-Guard an/aus/erster Wert]';

END $$;

ROLLBACK;
