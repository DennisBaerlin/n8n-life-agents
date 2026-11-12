-- finance.fn_feed_refresh_due(p_feed text) -> boolean: "muss der Kurs-Abruf heute noch nachgeholt werden?" (READ)
--   Eine Adresse fuer das Nachholen der Kurs-Crons (cron_refresh_fx_rates, cron_refresh_market_prices): n8n-Start und
--   Stunden-Check fragen hier, die DB entscheidet. Ein Abruf je Kalendertag der Haushalts-Zeitzone (core.fn_today),
--   Wochenende und Feiertag kosten daher nur einen Abruf.
--   Eingabe: p_feed 'fx' | 'prices' (anderer Wert -> RAISE).
--   Rueckgabe: true, wenn der juengste Stand (max updated_at) vor dem Beginn des heutigen Kalendertags liegt.
--     fx: Nenner = EUR-Kurse der aktiven Fremdwaehrungen (fn_active_currencies); gar kein Kurs -> true;
--         keine Fremdwaehrung -> false.
--     prices: Nenner = market_prices der gehaltenen Symbole (shares > 0); ein einzelnes nie bepreistes Symbol zaehlt
--         nicht (sonst fragte ein unaufloesbares Symbol stuendlich Yahoo an; das meldet cron_remind_missing_prices);
--         hat KEINE gehaltene Position je einen Kurs -> true (der Tagesplan muss dann abrufen, auch wenn der
--         Sofort-Abruf scheiterte); keine gehaltene Position -> false.
--   Unabhaengig von fx_stale_days/advisor.price_stale_days (7 Tage, Anzeige und Berater).
--   Seiteneffekte: keine. plpgsql, STABLE, INVOKER (finance_rw und finance_ro lesen nur finance.*).
--   Tests: tests/db/finance/test_fn_feed_refresh_due.sql
CREATE OR REPLACE FUNCTION finance.fn_feed_refresh_due(p_feed text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_n    int;
  v_last timestamptz;
BEGIN
  IF p_feed = 'fx' THEN
    SELECT count(ac.code), max(fxr.updated_at) INTO v_n, v_last
    FROM finance.fn_active_currencies() ac
    LEFT JOIN finance.fx_rates fxr ON fxr.base_currency = 'EUR' AND fxr.quote_currency = ac.code;
    RETURN v_n > 0 AND (v_last IS NULL OR core.fn_today(v_last) < core.fn_today());
  ELSIF p_feed = 'prices' THEN
    SELECT (SELECT count(*) FROM finance.depot_holdings WHERE shares > 0),
           (SELECT max(mp.updated_at) FROM finance.market_prices mp
            WHERE mp.symbol IN (SELECT h.symbol FROM finance.depot_holdings h WHERE h.shares > 0))
    INTO v_n, v_last;
    RETURN v_n > 0 AND (v_last IS NULL OR core.fn_today(v_last) < core.fn_today());
  END IF;
  RAISE EXCEPTION 'fn_feed_refresh_due: p_feed must be fx or prices, got %', p_feed;
END $$;
