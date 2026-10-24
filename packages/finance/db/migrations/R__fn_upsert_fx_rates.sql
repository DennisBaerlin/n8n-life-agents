-- packages/finance/db/migrations/R__fn_upsert_fx_rates.sql
-- Atomarer FX-Kurs-Upsert (A4b). Extrahiert aus dem Inline-SQL des Cron-Nodes
-- agent.finance.cron_refresh_fx_rates, damit die Upsert-Invarianten deterministisch testbar sind
-- (tests/db/finance/test_fn_upsert_fx_rates.sql) statt nur im Workflow-Node zu leben — "invariants as deep
-- as possible". Der Cron-Node ruft jetzt nur noch SELECT finance.fn_upsert_fx_rates($1::jsonb).
--
-- p = { "rates": { "USD": 1.08, "KRW": 1450, ... },   (Pflicht: open.er-api.com-Antwortobjekt)
--       "as_of":  "2026-06-07",                         (optional, default CURRENT_DATE)
--       "source": "open.er-api.com" }                   (optional, default 'open.er-api.com')
--
-- Guards (alle still -> kein RAISE, kein Owner-Alert; eine kaputte Waehrung darf den Tages-Refresh
-- der anderen nicht killen):
--   * nur Waehrungen aus finance.fn_active_currencies() — Objekt-getrieben, kein Cron-Spam fuer KRW ohne Konto
--   * Key muss im rates-Objekt existieren
--   * Wert numerisch UND > 0 (faengt 0-/Negativ-/"n/a"-Kurse ab -> sonst CHECK(rate>0)-RAISE)
-- ON CONFLICT (base, quote, as_of) -> idempotenter Tages-Upsert.
CREATE OR REPLACE FUNCTION finance.fn_upsert_fx_rates(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_as_of  date := COALESCE(NULLIF(p->>'as_of','')::date, CURRENT_DATE);
  v_source text := COALESCE(NULLIF(p->>'source',''), 'open.er-api.com');
  v_count  int;
BEGIN
  IF p->'rates' IS NULL OR jsonb_typeof(p->'rates') <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no rates object in payload', 'upserted', 0);
  END IF;

  WITH upserted AS (
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
    SELECT 'EUR', c.code, ((p->'rates')->>(c.code::text))::numeric, v_as_of, v_source
    FROM finance.fn_active_currencies() c(code)
    WHERE (p->'rates') ? c.code::text
      AND ((p->'rates')->>(c.code::text)) ~ '^[0-9]+(\.[0-9]+)?$'
      AND ((p->'rates')->>(c.code::text))::numeric > 0
    ON CONFLICT (base_currency, quote_currency, as_of)
    DO UPDATE SET rate = EXCLUDED.rate, source = EXCLUDED.source, updated_at = NOW()
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM upserted;

  RETURN jsonb_build_object('ok', true, 'upserted', v_count, 'as_of', v_as_of);
END $$;
