-- fn_feed_refresh_due (READ) -- "muss der Kurs-Abruf heute noch nachgeholt werden?"
--   Eine Adresse fuer das Nachholen der Kurs-Crons (cron_refresh_fx_rates, cron_refresh_market_prices): n8n-Start und
--   Stunden-Check fragen hier, die DB entscheidet. Ein Abruf je Kalendertag der Haushalts-Zeitzone (core.fn_today),
--   Wochenende und Feiertag kosten daher nur einen Abruf.
--   Eingabe: p_feed 'fx' | 'prices' (anderer Wert -> RAISE).
--   Rueckgabe: true, wenn der juengste Stand (max updated_at) vor dem Beginn des heutigen Kalendertags liegt.
--     fx: nur Zeilen des Tages-Feeds (source = fn_fx_feed_source(), beliebige Waehrung; ein EZB-Nachlauf ersetzt keinen
--         Tages-Abruf); gar keine -> true. Zusaetzlich faellig, solange der juengste Quell-Stand (as_of = UTC-Datum der
--         Veroeffentlichung) vor dem UTC-Datum von vor einer Stunde liegt: die Quelle veroeffentlicht gegen 00:02-00:26 UTC,
--         ein Abruf davor (Haushalt oestlich von UTC) holt noch den Vortag und wird nachgeholt. Unabhaengig von Konten und
--         Positionen: die Kurs-Vorhaltung haengt nicht am Bedarf. Ob die Quelle ausgefallen ist, sagt fn_fx_feed_gap.
--     prices: Nenner = market_prices der gehaltenen Symbole (shares > 0); ein einzelnes nie bepreistes Symbol zaehlt
--         nicht (sonst fragte ein unaufloesbares Symbol stuendlich Yahoo an; das meldet cron_remind_missing_prices);
--         hat keine gehaltene Position je einen Kurs -> true (der Tagesplan muss dann abrufen, auch wenn der
--         Sofort-Abruf scheiterte); keine gehaltene Position -> false.
--   Unabhaengig von fx_stale_days/advisor.price_stale_days (7 Tage, Anzeige und Berater).
--   Seiteneffekte: keine. plpgsql, STABLE, SECURITY INVOKER (finance_rw und finance_ro lesen nur finance.*).
--   Tests: tests/db/finance/test_fn_feed_refresh_due.sql
CREATE OR REPLACE FUNCTION finance.fn_feed_refresh_due(p_feed text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_n    int;
  v_last timestamptz;
  v_asof date;
BEGIN
  IF p_feed = 'fx' THEN
    -- beide Lesungen ueber idx_fx_rates_source_as_of; updated_at des juengsten Stands = letzter erfolgreicher Abruf
    SELECT max(fxr.as_of) INTO v_asof FROM finance.fx_rates fxr WHERE fxr.source = finance.fn_fx_feed_source();
    IF v_asof IS NULL THEN RETURN true; END IF;
    SELECT max(fxr.updated_at) INTO v_last FROM finance.fx_rates fxr
    WHERE fxr.source = finance.fn_fx_feed_source() AND fxr.as_of = v_asof;
    RETURN core.fn_today(v_last) < core.fn_today()
        OR v_asof < ((now() - interval '1 hour') AT TIME ZONE 'UTC')::date;
  ELSIF p_feed = 'prices' THEN
    SELECT (SELECT count(*) FROM finance.depot_holdings WHERE shares > 0),
           (SELECT max(mp.updated_at) FROM finance.market_prices mp
            WHERE mp.symbol IN (SELECT h.symbol FROM finance.depot_holdings h WHERE h.shares > 0))
    INTO v_n, v_last;
    RETURN v_n > 0 AND (v_last IS NULL OR core.fn_today(v_last) < core.fn_today());
  END IF;
  RAISE EXCEPTION 'fn_feed_refresh_due: p_feed must be fx or prices, got %', p_feed;
END $$;
