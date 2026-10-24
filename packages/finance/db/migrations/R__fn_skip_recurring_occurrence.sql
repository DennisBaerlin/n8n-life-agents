-- ============================================================
-- fn_skip_recurring_occurrence (ATOMIC WRITE)
--   Markiert ein faelliges Vorkommen als "fuer diese Periode uebersprungen" (Skip-Zeile).
--   Danach erscheint es nicht mehr in fn_recurring_due_open. Eingabe jsonb:
--   recurring_payment_id, due_date.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_skip_recurring_occurrence(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date)
    VALUES ((p->>'recurring_payment_id')::int, (p->>'due_date')::date)
    ON CONFLICT (recurring_payment_id, due_date) DO NOTHING;
    RETURN jsonb_build_object('ok', true);
END;
$$;
