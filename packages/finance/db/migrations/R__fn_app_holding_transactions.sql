-- ============================================================
-- finance.fn_app_holding_transactions(p_holding_id int) — Buchungs-Zeilen einer Depot-Position fuer das Aufklappen in
--   der Mini-App (READ, Baustein von finance.fn_app_screen_depot; View-Modell v1 item.details, docs/package-contract.md
--   §3.12). Liefert [{label:<tpl>, value:<money>}]: die letzten 12 Buchungen der Position (Kauf/Verkauf/Dividende,
--   neueste zuerst; Stueckpreis = unit_price bzw. |Betrag| / Stueck inkl. Gebuehr, Broker-Konvention; Betrag positiv in
--   der Waehrung des Buchungskontos) und „n aeltere Buchungen", wenn es mehr gibt. Die Kennzahlen davor (Ø Kaufkurs,
--   Kaufwert, Gewinn) baut der Handler aus seinen eigenen Zeilen (kein zweiter Lauf ueber depot_holdings_overview).
--   Keine IDs, keine Kontonamen. Die Sichtbarkeit prueft der aufrufende Handler (er ruft nur fuer sichtbare
--   Positionen); deshalb REVOKE PUBLIC, der DEFINER-Handler ruft als Eigentuemer.
--   Tests: tests/db/finance/test_fn_app_holding_transactions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_holding_transactions(p_holding_id int)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_out jsonb;
BEGIN
    WITH tx AS (
        SELECT t.transaction_date, t.category, t.amount, t.shares, t.unit_price, ta.currency,
               row_number() OVER (ORDER BY t.transaction_date DESC, t.id DESC) AS rn,
               count(*) OVER () AS cnt
          FROM finance.transactions t
          JOIN finance.accounts ta ON ta.id = t.account_id
         WHERE t.holding_id = p_holding_id AND t.category IN ('buy', 'sell', 'dividend')
    ), x AS (
        SELECT tx.rn AS o, jsonb_build_object(
                   'label', CASE tx.category
                       WHEN 'dividend' THEN core.fn_ui_tpl('finance.app.depot.tx_dividend', jsonb_build_object(
                                                'date', core.fn_ui_date(tx.transaction_date)))
                       ELSE core.fn_ui_tpl(CASE tx.category WHEN 'buy' THEN 'finance.app.depot.tx_buy'
                                                            ELSE 'finance.app.depot.tx_sell' END,
                                jsonb_build_object(
                                    'date', core.fn_ui_date(tx.transaction_date),
                                    'shares', core.fn_ui_num(abs(tx.shares), scale(trim_scale(abs(tx.shares)))),
                                    'price', core.fn_ui_money(COALESCE(tx.unit_price, abs(tx.amount) / abs(tx.shares)),
                                                              tx.currency))) END,
                   'value', core.fn_ui_money(abs(tx.amount), tx.currency)) AS d
          FROM tx
         WHERE tx.rn <= 12
        UNION ALL
        SELECT 1000, jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.tx_more', jsonb_build_object(
                         'count', core.fn_ui_num(max(tx.cnt) - 12, 0))), 'value', NULL)
          FROM tx
        HAVING max(tx.cnt) > 12
    )
    SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) INTO v_out FROM x;
    RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_holding_transactions(int) FROM public;
