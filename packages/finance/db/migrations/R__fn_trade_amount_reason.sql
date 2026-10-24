-- ============================================================
-- fn_trade_amount_reason (READ HELPER) -- Kauf/Verkauf: gebuchter Betrag und Stueckzahl (Rundungs-Paket 2026-10-23)
--   EINE Adresse fuer fn_book_stock_buy und fn_book_stock_sell. Liefert NULL, wenn die Buchung so moeglich ist, sonst den
--   korrigierbaren Grund (EN, fuers {ok:false}):
--     * Stueckzahl mit mehr als 8 Nachkommastellen: transactions.shares/depot_holdings.shares sind numeric(18,8) und
--       wuerden still kuerzen.
--     * gebuchter Betrag (auf Cent gerundet) <= 0: Mini-Kauf unter einem halben Cent bzw. Verkauf, dessen Gebuehr den
--       Erloes erreicht. Vorher brach das am CHECK finance_transactions_category_consistency (buy amount<0 /
--       sell amount>0) mit RAISE + Owner-Alert ab.
--   p_net = Betrag aus Sicht des Kontos VOR der Cent-Rundung: Kauf shares*price+fee (wird abgebucht), Verkauf
--   shares*price-fee (wird gutgeschrieben); beide muessen nach der Rundung > 0 sein.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_trade_amount_reason(p_shares numeric, p_net numeric)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_shares IS NOT NULL AND p_shares <> round(p_shares, 8) THEN
        RETURN 'Share count ' || p_shares || ' has more than 8 decimal places - give it with at most 8.';
    END IF;
    IF p_net IS NOT NULL AND round(p_net, 2) <= 0 THEN
        RETURN 'The booked amount would be ' || round(p_net, 2) || ' (less than one cent or the fee eats the proceeds) '
            || '- check the share count, price and order fee.';
    END IF;
    RETURN NULL;
END;
$$;
