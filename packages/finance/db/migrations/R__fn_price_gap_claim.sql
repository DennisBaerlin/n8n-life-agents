-- ============================================================
-- finance.fn_price_gap_claim(p_key) — Latch der Kurs-Luecken-Erinnerung (Kurs-Luecken 2026-10-27)
--   true GENAU DANN, wenn die Luecke <p_key> (holding_id als Text oder 'feed_down') jetzt gemeldet werden soll:
--   erste Meldung oder 7 Tage nach der letzten (core.fn_should_notify mit TTL, source 'finance_prices'). Der Cron
--   ruft das je Position DIREKT vor dem eigenen Versand (nie fuer alle vorab: eine nicht angetippte Karte darf die
--   naechste nicht verschlucken). Re-Arm nach Behebung macht fn_price_gaps.
--   VERTRAG (wie fn_should_notify): nur fuer eine Luecke aufrufen, die laut fn_price_gaps gerade besteht.
--   Tests: tests/db/finance/test_fn_price_gaps.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_price_gap_claim(p_key text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    RETURN core.fn_should_notify('finance_prices', p_key, interval '7 days');
END;
$$;
