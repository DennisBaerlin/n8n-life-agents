-- tests/db/core/test_fn_resolve_input_dates.sql
-- core.fn_resolve_input_dates(p, keys, today): die genannten Datums-Keys eines Tool-Payloads einmal aufloesen
--   (relativ -> ISO ueber core.fn_resolve_date). Ergebnis {ok:true, p, resolved} bzw. {ok:false, code:'invalid_date',
--   reason} — Daten, nie eine Exception. Fester Bezugstag 2026-10-25 (ein Sonntag).
BEGIN;

DO $$
DECLARE
  t date := '2026-10-25';
  r jsonb;
BEGIN
  -- ---------- relativ -> ISO, ISO bleibt, andere Keys unberuehrt ----------
  r := core.fn_resolve_input_dates(
         '{"transaction_date":"yesterday","valid_to":"2026-12-31","amount":"12.5","note":"in 3 days"}'::jsonb,
         ARRAY['transaction_date', 'valid_to'], t);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [ok: %]', r; END IF;
  IF r->'p'->>'transaction_date' IS DISTINCT FROM '2026-10-24' THEN RAISE EXCEPTION 'FAIL [relativ -> ISO: %]', r; END IF;
  IF r->'p'->>'valid_to' IS DISTINCT FROM '2026-12-31' THEN RAISE EXCEPTION 'FAIL [ISO bleibt: %]', r; END IF;
  IF r->'p'->>'note' IS DISTINCT FROM 'in 3 days' OR r->'p'->>'amount' IS DISTINCT FROM '12.5' THEN
    RAISE EXCEPTION 'FAIL [fremde Keys unberuehrt: %]', r; END IF;
  IF r->'resolved' IS DISTINCT FROM '{"transaction_date":"2026-10-24","valid_to":"2026-12-31"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [resolved: %]', r->'resolved'; END IF;

  -- ---------- Tage genau, auch bei Monats-/Jahres-Offsets (kein YYYY-MM wie bei Fakten) ----------
  r := core.fn_resolve_input_dates('{"first_payment_date":"in 1 month","term_end_date":"+2 years"}'::jsonb,
         ARRAY['first_payment_date', 'term_end_date'], t);
  IF r->'p'->>'first_payment_date' IS DISTINCT FROM '2026-11-25' OR r->'p'->>'term_end_date' IS DISTINCT FROM '2028-10-25' THEN
    RAISE EXCEPTION 'FAIL [Tag genau: %]', r; END IF;

  -- ---------- fehlend / leer / JSON-null bleiben, resolved leer ----------
  r := core.fn_resolve_input_dates('{"transaction_date":"","valid_to":null}'::jsonb,
         ARRAY['transaction_date', 'valid_to', 'closure_date'], t);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'resolved' IS DISTINCT FROM '{}'::jsonb
     OR r->'p' IS DISTINCT FROM '{"transaction_date":"","valid_to":null}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [leer/null/fehlend: %]', r; END IF;

  -- ---------- nicht aufloesbar -> ok:false als Daten, Key im Grund ----------
  r := core.fn_resolve_input_dates('{"transaction_date":"Ende des Monats"}'::jsonb, ARRAY['transaction_date'], t);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'invalid_date'
     OR position('transaction_date' IN r->>'reason') = 0 THEN
    RAISE EXCEPTION 'FAIL [ungueltig -> ok:false: %]', r; END IF;
  IF r ? 'p' OR r ? 'resolved' THEN RAISE EXCEPTION 'FAIL [Ablehnung ohne p/resolved: %]', r; END IF;
  r := core.fn_resolve_input_dates('{"valid_from":"2024-02-30"}'::jsonb, ARRAY['valid_from'], t);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [ungueltiges ISO: %]', r; END IF;

  -- ---------- Nicht-String (Zahl) unter einem Datums-Key = ungueltig, kein Cast-Fehler ----------
  r := core.fn_resolve_input_dates('{"transaction_date":20261024}'::jsonb, ARRAY['transaction_date'], t);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [Zahl: %]', r; END IF;

  -- ---------- idempotent: zweiter Lauf auf dem Ergebnis aendert nichts ----------
  r := core.fn_resolve_input_dates('{"sale_date":"last friday"}'::jsonb, ARRAY['sale_date'], t);
  IF core.fn_resolve_input_dates(r->'p', ARRAY['sale_date'], t)->'p' IS DISTINCT FROM r->'p'
     OR r->'p'->>'sale_date' IS DISTINCT FROM '2026-10-23' THEN
    RAISE EXCEPTION 'FAIL [idempotent: %]', r; END IF;

  -- ---------- Default-Bezugstag = core.fn_today() ----------
  r := core.fn_resolve_input_dates('{"d_date":"today"}'::jsonb, ARRAY['d_date']);
  IF (r->'p'->>'d_date')::date IS DISTINCT FROM core.fn_today() THEN RAISE EXCEPTION 'FAIL [Default heute: %]', r; END IF;

  -- ---------- NULL-Payload / leere Key-Liste ----------
  r := core.fn_resolve_input_dates(NULL, ARRAY['x_date'], t);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'p' IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'FAIL [NULL-p: %]', r; END IF;
  r := core.fn_resolve_input_dates('{"a_date":"yesterday"}'::jsonb, ARRAY[]::text[], t);
  IF r->'p'->>'a_date' IS DISTINCT FROM 'yesterday' THEN RAISE EXCEPTION 'FAIL [leere Key-Liste: %]', r; END IF;

  RAISE NOTICE 'PASS [core.fn_resolve_input_dates]';
END;
$$;

ROLLBACK;
