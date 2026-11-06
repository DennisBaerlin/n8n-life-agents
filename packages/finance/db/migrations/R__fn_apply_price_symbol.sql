-- ============================================================
-- finance.fn_apply_price_symbol(p jsonb) — Kurs-Symbol aus der Luecken-Karte uebernehmen (ATOMIC WRITE, 2026-10-27)
--   Laeuft hinter dem [Uebernehmen]-Tipp der Karte aus agent.finance.cron_remind_missing_prices (der Tipp ist das
--   HITL). Zwischen Karte und Tipp koennen Stunden liegen -> Guard ZUERST: die Position ist noch gehalten, ihre
--   Kurs-Luecke besteht noch (fn_holding_price_status <> ok) und ihr Feed-Symbol ist noch das der Karte
--   (expected_feed_symbol). Sonst {ok:false, code:'already_resolved'} (der Owner hat inzwischen selbst korrigiert)
--   bzw. code:'not_found'. Dann Delegation an fn_set_holding (Waehrungs-Validierung, Dubletten-Abfang).
--   quote_currency wird IMMER gesetzt (auch EUR): fn_set_holding kann sie nicht leeren, ein altes USD bliebe sonst.
--   Eingabe: holding_id, expected_feed_symbol, provider_symbol (Yahoo-Ticker, wird gross geschrieben), quote_currency.
--   RUECKGABE ok:true: { holding_id, feed_symbol } (Post-State: das jetzt angefragte Symbol).
--   Tests: tests/db/finance/test_fn_apply_price_symbol.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_apply_price_symbol(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_id     int  := NULLIF(p->>'holding_id', '')::int;
    v_sym    text := upper(trim(COALESCE(p->>'provider_symbol', '')));
    v_ccy    text := NULLIF(trim(COALESCE(p->>'quote_currency', '')), '');
    v_status text;
    v_feed   text;
    v_r      jsonb;
BEGIN
    IF v_sym = '' OR v_ccy IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'provider_symbol and quote_currency are required.');
    END IF;

    -- Zeile sperren: zwei Tipps gleichzeitig serialisieren
    PERFORM 1 FROM finance.depot_holdings WHERE id = v_id FOR UPDATE;
    SELECT s.status, s.feed_symbol INTO v_status, v_feed
    FROM finance.fn_holding_price_status(ARRAY[v_id]) s;
    IF v_status IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'This position is no longer held.');
    END IF;
    IF v_status = 'ok' OR v_feed IS DISTINCT FROM NULLIF(p->>'expected_feed_symbol', '') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_resolved',
            'reason', 'The price source of this position was changed or a price arrived in the meantime.');
    END IF;

    v_r := finance.fn_set_holding(jsonb_build_object('holding_id', v_id, 'provider_symbol', v_sym, 'quote_currency', v_ccy));
    IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN
        RETURN v_r;
    END IF;

    SELECT h.feed INTO v_feed
    FROM (SELECT finance.fn_feed_symbol(isin, symbol, provider_symbol) AS feed
          FROM finance.depot_holdings WHERE id = v_id) h;
    RETURN jsonb_build_object('ok', true, 'holding_id', v_id, 'feed_symbol', v_feed);
END;
$$;
