-- ============================================================
-- fn_price_gap_claim (WRITE, Latch, VOLATILE — Latch der Kurs-Luecken-Erinnerung)
--   true genau dann, wenn die Luecke <p_key> (holding_id als Text oder 'feed_down') jetzt gemeldet werden soll:
--   erste Meldung oder 7 Tage nach der letzten (core.fn_should_notify mit TTL, source 'finance:prices', Reset raeumt <pkg>:<sub>). Der Cron
--   ruft das je Position direkt vor dem eigenen Versand (nie fuer alle vorab: eine nicht angetippte Karte darf die
--   naechste nicht verschlucken). Re-Arm nach Behebung macht fn_price_gaps.
--   Eingabe: p_key (text). Rueckgabe: boolean. Seiteneffekt: Slot-/Latch-Merker in core (fn_proactive_claim,
--   fn_should_notify).
--   Budget: Lueckenkarten haben je einen eigenen Vorschlag und lassen sich nicht buendeln: hoechstens eine Karte je Tag
--   (Merker 'card_today', 20 h), Slot 'price_gap' normal; 'feed_down' eigener Slot. Schon gemeldet -> kein Slot.
--   Vertrag (wie fn_should_notify): nur fuer eine Luecke aufrufen, die laut fn_price_gaps gerade besteht.
--   Tests: tests/db/finance/test_fn_price_gaps.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_price_gap_claim(p_key text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF core.fn_notify_told('finance:prices', p_key) THEN RETURN false; END IF;
    IF p_key = 'feed_down' THEN
        IF NOT core.fn_proactive_claim(NULL, 'price_feed_down', 'normal') THEN RETURN false; END IF;
        RETURN core.fn_should_notify('finance:prices', p_key, interval '7 days');
    END IF;
    IF NOT core.fn_proactive_claim(NULL, 'price_gap', 'normal') THEN RETURN false; END IF;
    IF NOT core.fn_should_notify('finance:prices', 'card_today', interval '20 hours') THEN RETURN false; END IF;
    RETURN core.fn_should_notify('finance:prices', p_key, interval '7 days');
END;
$$;
