-- ============================================================
-- fn_resolve_recurring_payment
--   Loest den Namen einer STANDALONE wiederkehrenden Zahlung in ID auf (Vorbild fn_resolve_account).
--   p_active_only: default TRUE -> nur status='active' (die aktuell laufende Zeile, die man aendert).
--   Mehrdeutigkeit (hit_count/candidates) -> Tool fragt nach.
--   Abgeloeste Glieder einer Vorgaenger-Kette (Zeile mit Nachfolger, Audit Paket 2 A0) sind KEINE Kandidaten:
--   nach einem Split traegt die alte Zeile denselben Namen; geaendert wird immer der Kopf.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_recurring_payment(
    p_name        text,
    p_active_only boolean DEFAULT TRUE
) RETURNS TABLE (
    id          int,
    hit_count   int,
    candidates  jsonb
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_candidates JSONB;
    v_count      INT;
    v_id         INT;
    v_exact      BOOLEAN;
BEGIN
    FOREACH v_exact IN ARRAY ARRAY[TRUE, FALSE] LOOP
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',         rp.id,
            'name',       rp.name,
            'amount',     rp.amount,
            'account_id', rp.account_id,
            'status',     rp.status,
            'valid_from', rp.valid_from,
            'last_valid_day', rp.valid_to - 1   -- valid_to ist exklusiv gespeichert; dem Nutzer das inklusive Ende zeigen
        ) ORDER BY rp.id),
        COUNT(*),
        MIN(rp.id)
    INTO v_candidates, v_count, v_id
    FROM finance.recurring_payments rp
    WHERE finance.fn_name_matches(rp.name, p_name, v_exact)
      AND (p_active_only = FALSE OR rp.status = 'active')
      AND NOT EXISTS (SELECT 1 FROM finance.recurring_payments s WHERE s.predecessor_id = rp.id);
    EXIT WHEN v_count > 0;
    END LOOP;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
