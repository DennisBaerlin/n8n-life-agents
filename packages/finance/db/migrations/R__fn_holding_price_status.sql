-- ============================================================
-- finance.fn_holding_price_status(p_holding_ids) — Kurs-Status je gehaltener Position (READ, Kurs-Luecken 2026-10-27)
--   EINE Adresse fuer "hat diese Position einen Kurs?": Kurs-Luecken-Erinnerung (fn_price_gaps), Tool-Antworten
--   nach dem Sofort-Kursabruf (book_stock_buy/set_holding/commit_import/book_savings_plan_execution),
--   fn_apply_price_symbol (Guard) und fn_advisor_review (null_price). Status-Regel = finance.fn_price_status
--   (Init-Helfer; missing | stale | ok), angefragtes Symbol = finance.fn_feed_symbol.
--   Nur gehaltene Positionen (shares > 0); p_holding_ids NULL = alle.
--   RUECKGABE je Zeile: holding_id, name, symbol, isin, feed_symbol, account_name, currency (Holding/Buchwert),
--     avg_price, price (juengster market_prices-Kurs, NULL ohne Kurs), price_currency, price_as_of, status.
--   plpgsql (late-bound, Muster R__-Reihenfolge), STABLE, INVOKER: liest nur finance.* (+ core.fn_config_get
--   ueber fn_price_status, beide Paket-Rollen haben den Grant).
--   Tests: tests/db/finance/test_fn_holding_price_status.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_holding_price_status(p_holding_ids int[] DEFAULT NULL)
RETURNS TABLE (
    holding_id     int,
    name           text,
    symbol         text,
    isin           text,
    feed_symbol    text,
    account_name   text,
    currency       text,
    avg_price      numeric,
    price          numeric,
    price_currency text,
    price_as_of    date,
    status         text
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT h.id,
           h.name::text,
           h.symbol::text,
           h.isin::text,
           finance.fn_feed_symbol(h.isin, h.symbol, h.provider_symbol),
           a.name::text,
           h.currency::text,
           h.average_purchase_price,
           lp.price,
           lp.currency::text,
           lp.as_of,
           finance.fn_price_status(lp.as_of)
    FROM finance.depot_holdings h
    JOIN finance.accounts a ON a.id = h.account_id
    LEFT JOIN LATERAL (
        SELECT mp.price, mp.currency, mp.as_of
        FROM finance.market_prices mp
        WHERE mp.symbol = h.symbol
        ORDER BY mp.as_of DESC
        LIMIT 1
    ) lp ON true
    WHERE h.shares > 0
      AND (p_holding_ids IS NULL OR h.id = ANY (p_holding_ids))
    ORDER BY h.id;
END;
$$;
