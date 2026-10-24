-- ============================================================
-- fn_holding_symbol (READ, IMMUTABLE) -- die Kennung einer Depot-Position (depot_holdings.symbol)
--   = genannter Ticker, sonst die ISIN. Owner-Befund 2026-10-23: eine Trade-Republic-Vermoegensuebersicht druckt je
--   Position nur die ISIN; ein Ticker ist dann nicht bekannt und wird nie geraten. Die ISIN ist eindeutig und dient
--   als Join-Key fuer finance.market_prices (PK symbol, as_of) -- bewusst KEIN gekuerzter Yahoo-Ticker
--   (provider_symbol 'SAP.DE' -> 'SAP' wuerde Kurse fremder Listings unter demselben Schluessel mischen). Den
--   Kurs-Feed steuert provider_symbol (tool_commit_import loest die ISIN bei Yahoo auf).
--   EINE Adresse fuer fn_book_stock_buy (Write), fn_import_card_rows (Kartenwert) und fn_import_validate_row.
--   RUECKGABE text (NULL = weder Ticker noch ISIN).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_holding_symbol(p_symbol text, p_isin text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(NULLIF(btrim(p_symbol), ''), NULLIF(btrim(p_isin), ''));
$$;
