-- packages/finance/db/migrations/R__fn_active_currencies.sql
-- fn_active_currencies (READ, STABLE)
-- Keine Eingabe. Rueckgabe: Tabelle (code) der verschiedenen Nicht-EUR-Waehrungen, die ein lebendes Finance-Objekt
-- nutzt (accounts.currency, depot_holdings.currency/quote_currency, die Waehrung des juengsten Kurses einer
-- gehaltenen Position in finance.market_prices). EUR ist die Reporting-Basis und fehlt immer. Die Menge folgt den
-- tatsaechlichen Objekten, nicht manuell gepflegten Stammdaten; sie treibt cron.refresh_fx_rates.
--
-- quote_currency ist die native Markt-Waehrung einer ggf. EUR-gefuehrten Position
-- (US-Listing in USD, Position aber EUR aufgenommen -> currency='EUR', quote_currency='USD').
-- Ohne diese UNION holt der FX-Cron den USD-Kurs nie -> market_value_eur bleibt NULL -> die
-- Position zaehlt still 0 im Net-Worth.
--
-- Geschlossene Konten bleiben drin: sonst entstuenden in Roll-up-Views NULL-Fenster fuer den
-- letzten Handelstag vor der Schliessung.
-- Tests: tests/db/finance/test_fn_active_currencies.sql
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
  -- die Waehrung, in der der Feed einen Kurs tatsaechlich liefert (Yahoo-meta.currency gewinnt in
  -- fn_upsert_market_prices), auch ohne quote_currency (z. B. Krypto-Feed mit USD-Kurs, Alt-Positionen). Sonst fehlt
  -- der FX-Kurs und market_value_eur bleibt NULL (nur has_fx_gap). Nur gehaltene Positionen und nur der juengste Kurs je
  -- Symbol (derselbe Kurs, den depot_holdings_overview bewertet): ein Wechsel auf eine EUR-Notierung beendet den FX-Bedarf.
  SELECT DISTINCT lp.currency::text
  FROM (SELECT DISTINCT ON (mp.symbol) mp.symbol, mp.currency
        FROM finance.market_prices mp
        JOIN finance.depot_holdings h ON h.symbol = mp.symbol AND h.shares > 0
        ORDER BY mp.symbol, mp.as_of DESC) lp
  WHERE lp.currency IS NOT NULL AND lp.currency <> 'EUR'
$$;
