-- ============================================================
-- fn_next_check (STABLE HELPER)
--   Anker-erhaltender Cadence-Advance: berechnet den naechsten Pruefzeitpunkt eines Monitor-Triggers.
--   Eingabe: p_prev, p_interval, p_now (alle Pflicht; p_interval NULL oder <= 0 -> RAISE).
--   Rueckgabe: p_prev + p_interval * k mit minimalem k, sodass das Ergebnis strikt > p_now liegt.
--   Eigenschaften (Tests: tests/db/core/test_fn_next_check.sql):
--     * Anker bleibt erhalten ("jeden Tag 09:00" bleibt 09:00, Montag bleibt Montag)
--     * Catch-up: nach Downtime werden verpasste Slots uebersprungen, nicht nachgefeuert
--       (sonst wuerde ein ueberfaelliger Trigger auf jedem Heartbeat erneut feuern)
--     * p_now exakt auf einem Slot -> naechster Slot (nie <= p_now)
--   Die Epoch-Division ist bei Kalender-Intervallen (Monate) eine Naeherung; die
--   While-Korrektur garantiert "strikt in der Zukunft" trotzdem hart.
--   STABLE statt IMMUTABLE: timestamptz + Kalender-Intervall (Tag/Monat) haengt an der Sitzungs-Zeitzone (Sommerzeit).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_next_check(
    p_prev     timestamptz,
    p_interval interval,
    p_now      timestamptz
) RETURNS timestamptz LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_k    BIGINT;
    v_next TIMESTAMPTZ;
BEGIN
    IF p_interval IS NULL OR p_interval <= INTERVAL '0' THEN
        RAISE EXCEPTION 'fn_next_check: interval must be positive, got %', p_interval;
    END IF;

    v_k := GREATEST(1::bigint,
        FLOOR(EXTRACT(EPOCH FROM (p_now - p_prev)) / EXTRACT(EPOCH FROM p_interval))::bigint + 1);
    -- Die Naeherung (Monat = 30 Tage) schiesst bei Monats-Intervallen nach langer Pause auch ueber das minimale k
    -- hinaus (prev 01.01., now 31.12. -> k 13 statt 12): erst zurueck, solange der vorige Slot noch > now liegt.
    WHILE v_k > 1 AND p_prev + p_interval * (v_k - 1) > p_now LOOP
        v_k := v_k - 1;
    END LOOP;
    v_next := p_prev + p_interval * v_k;

    -- Harte Garantie "strikt > p_now" (Kalender-Intervall-Naeherung korrigieren; max wenige Schritte)
    WHILE v_next <= p_now LOOP
        v_k := v_k + 1;
        v_next := p_prev + p_interval * v_k;
    END LOOP;

    RETURN v_next;
END;
$$;
