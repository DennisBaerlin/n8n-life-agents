-- ============================================================
-- finance.fn_price_gaps() — Kurs-Luecken fuer die taegliche Erinnerung (Kurs-Luecken 2026-10-27)
--   Liefert die gehaltenen Positionen ohne gueltigen Kurs (status missing|stale aus fn_holding_price_status) samt den
--   Plausi-Referenzen eines Symbol-Kandidaten (letzter Kurs price/price_currency, Einstand avg_price in currency) und
--   die EUR-FX-Saetze (fn_fx_rate_map; Kandidat in anderer Waehrung -> Vergleich in EUR).
--   FEED-AUSFALL: hat keine gehaltene Position einen gueltigen Kurs, aber >= 2 hatten schon einen (stale), liefert
--   Yahoo offenbar gar nichts -> feed_down=true, stale_since = juengster Kurs; der Cron sendet dann EINE Meldung statt
--   einer Karte je Position (die Symbol-Suche fiele ohnehin aus).
--   RE-ARM (Seiteneffekt, darum VOLATILE): jede Position OHNE Luecke (auch verkaufte) bekommt
--   core.fn_notify_resolve('finance_prices', <id>), ohne Feed-Ausfall auch der Key 'feed_down' -> eine spaeter neu
--   entstehende Luecke meldet sofort. Bewusst NICHT core.fn_notify_reconcile: das ist advisor-only (kein Paket-Grant,
--   R__fn_provision_package_roles). Gemeldet (gelatcht) wird erst im Cron je Karte via fn_price_gap_claim.
--   RUECKGABE jsonb: { feed_down, stale_since, fx:{CCY: rate EUR->CCY, EUR:1},
--     gaps:[{holding_id, name, isin, symbol, feed_symbol, account_name, currency, status, price, price_currency,
--            price_as_of, avg_price}] }
--   Tests: tests/db/finance/test_fn_price_gaps.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_price_gaps()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_gaps      jsonb;
    v_ok_cnt    int;
    v_stale_cnt int;
    v_since     date;
    v_feed_down boolean;
    v_fx        jsonb;
    v_id        int;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'holding_id',     s.holding_id,
               'name',           s.name,
               'isin',           s.isin,
               'symbol',         s.symbol,
               'feed_symbol',    s.feed_symbol,
               'account_name',   s.account_name,
               'currency',       s.currency,
               'status',         s.status,
               'price',          s.price,
               'price_currency', s.price_currency,
               'price_as_of',    s.price_as_of,
               'avg_price',      s.avg_price)
             ORDER BY s.holding_id) FILTER (WHERE s.status <> 'ok'), '[]'::jsonb),
           count(*) FILTER (WHERE s.status = 'ok'),
           count(*) FILTER (WHERE s.status = 'stale'),
           max(s.price_as_of)
    INTO v_gaps, v_ok_cnt, v_stale_cnt, v_since
    FROM finance.fn_holding_price_status() s;

    v_feed_down := v_ok_cnt = 0 AND v_stale_cnt >= 2;

    v_fx := finance.fn_fx_rate_map();

    -- Re-Arm behobener Luecken (inkl. verkaufter Positionen)
    FOR v_id IN
        SELECT h.id FROM finance.depot_holdings h
        WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_gaps) g WHERE (g->>'holding_id')::int = h.id)
    LOOP
        PERFORM core.fn_notify_resolve('finance_prices', v_id::text);
    END LOOP;
    IF NOT v_feed_down THEN
        PERFORM core.fn_notify_resolve('finance_prices', 'feed_down');
    END IF;

    RETURN jsonb_build_object(
        'feed_down',   v_feed_down,
        'stale_since', CASE WHEN v_feed_down THEN v_since END,
        'fx',          v_fx,
        'gaps',        v_gaps);
END;
$$;
