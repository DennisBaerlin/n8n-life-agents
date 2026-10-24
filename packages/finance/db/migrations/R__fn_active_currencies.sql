-- packages/finance/db/migrations/R__fn_active_currencies.sql
-- Returns DISTINCT non-EUR currencies in use by any live finance object
-- (finance_accounts.currency OR finance_depot_holdings.currency OR .quote_currency OR the currency a held
-- position's market price is actually quoted in, finance.market_prices.currency).
-- EUR is always the reporting base and is excluded. No finance_currencies dependency —
-- the set is driven by actual objects, not by what has been manually seeded.
--
-- WP-3a: quote_currency ist die native MARKT-Waehrung einer ggf. EUR-gefuehrten Position
-- (US-Listing in USD, Position aber EUR aufgenommen -> currency='EUR', quote_currency='USD').
-- Ohne diese UNION holt der FX-Cron den USD-Kurs nie -> market_value_eur bleibt NULL -> die
-- Position zaehlt still 0 im Net-Worth. Diese Menge treibt cron.refresh_fx_rates.
--
-- Closed accounts are kept: removing them would create NULL-windows in
-- roll-up views for the last trading day before account closure.
CREATE OR REPLACE FUNCTION finance.fn_active_currencies()
RETURNS TABLE (code text) LANGUAGE sql STABLE AS $$
  SELECT DISTINCT currency::text FROM finance.accounts
  WHERE currency <> 'EUR'
  UNION
  SELECT DISTINCT currency::text FROM finance.depot_holdings
  WHERE currency <> 'EUR'
  UNION
  SELECT DISTINCT quote_currency::text FROM finance.depot_holdings
  WHERE quote_currency IS NOT NULL AND quote_currency <> 'EUR'
  UNION
  -- 2026-10-23: die Waehrung, in der der Feed einen Kurs TATSAECHLICH liefert (Yahoo-meta.currency gewinnt in
  -- fn_upsert_market_prices), auch ohne quote_currency (z. B. Krypto-Feed UNI7083-USD, Alt-Positionen). Sonst fehlt
  -- der FX-Kurs und market_value_eur bleibt NULL (nur has_fx_gap). Nur gehaltene Positionen und nur der JUENGSTE Kurs je
  -- Symbol (derselbe Kurs, den depot_holdings_overview bewertet): ein Wechsel auf eine EUR-Notierung beendet den FX-Bedarf.
  SELECT DISTINCT lp.currency::text
  FROM (SELECT DISTINCT ON (mp.symbol) mp.symbol, mp.currency
        FROM finance.market_prices mp
        JOIN finance.depot_holdings h ON h.symbol = mp.symbol AND h.shares > 0
        ORDER BY mp.symbol, mp.as_of DESC) lp
  WHERE lp.currency IS NOT NULL AND lp.currency <> 'EUR'
$$;
