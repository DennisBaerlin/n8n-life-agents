-- ============================================================
-- finance.fn_fx_rate_map() — juengster EUR-Kurs je Fremdwaehrung als jsonb {CCY: rate, EUR: 1} (READ, 2026-10-27)
--   Fuer den Plausi-Check eines Kurs-Symbol-Kandidaten in Fremdwaehrung (agent.finance.sub_resolve_yahoo_symbol,
--   Input fx_rates): Kandidaten-Kurs und Referenzkurs werden in EUR verglichen. rate = Einheiten der Waehrung je 1 EUR
--   (finance.fx_rates base EUR), wie fn_to_eur. EINE Adresse fuer fn_price_gaps (Kurs-Luecken-Erinnerung) und
--   tool_set_holding/tool_verify_price_symbol.
--   Tests: tests/db/finance/test_fn_price_gaps.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_fx_rate_map()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('EUR', 1) || COALESCE(jsonb_object_agg(r.quote_currency, r.rate), '{}'::jsonb)
    FROM (SELECT DISTINCT ON (quote_currency) quote_currency, rate
          FROM finance.fx_rates
          WHERE base_currency = 'EUR'
          ORDER BY quote_currency, as_of DESC) r;
$$;
