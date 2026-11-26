-- ============================================================
-- fn_feed_down_claim (WRITE, Latch, VOLATILE) -- darf die Meldung "Kursdienst liefert nicht" jetzt raus?
--   Ein Claim fuer beide Kurs-Feeds des Erinnerungs-Crons (cron_remind_missing_prices): erste Meldung, dann
--   hoechstens alle 7 Tage, solange der Ausfall besteht (core.fn_should_notify mit TTL, keine Entwarnung). Re-Arm bei
--   Rueckkehr machen die Erkenner (fn_price_gaps fuer prices, fn_fx_feed_gap fuer fx) per core.fn_notify_resolve.
--   Eingabe: p_feed 'prices' | 'fx' (anderer Wert -> RAISE). Latch-Quelle finance:<feed>, Key feed_down; je Feed ein
--   eigener Budget-Slot (price_feed_down / fx_feed_down, Klasse normal): fallen beide Dienste gleichzeitig aus, kommen
--   zwei Meldungen. Schon gemeldet -> false ohne Slot.
--   Vertrag (wie fn_should_notify): nur aufrufen, wenn der Ausfall laut Erkenner gerade besteht.
--   Rueckgabe: boolean. Seiteneffekt: Slot-/Latch-Merker in core (fn_proactive_claim, fn_should_notify).
--   Tests: tests/db/finance/test_fn_price_gaps.sql, tests/db/finance/test_fn_fx_feed_gap.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_feed_down_claim(p_feed text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_source text;
    v_slot   text;
BEGIN
    IF p_feed = 'prices' THEN
        v_source := 'finance:prices'; v_slot := 'price_feed_down';
    ELSIF p_feed = 'fx' THEN
        v_source := 'finance:fx'; v_slot := 'fx_feed_down';
    ELSE
        RAISE EXCEPTION 'fn_feed_down_claim: p_feed must be prices or fx, got %', p_feed;
    END IF;
    IF core.fn_notify_told(v_source, 'feed_down') THEN RETURN false; END IF;
    IF NOT core.fn_proactive_claim(NULL, v_slot, 'normal') THEN RETURN false; END IF;
    RETURN core.fn_should_notify(v_source, 'feed_down', interval '7 days');
END;
$$;
