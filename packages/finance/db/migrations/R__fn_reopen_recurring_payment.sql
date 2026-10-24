-- ============================================================
-- fn_reopen_recurring_payment (INTERNAL HELPER — not tool-facing)
--   Reaktiviert eine BEENDETE recurring_payment (valid_to gesetzt, z. B. nach Soft-Close eines Sparplans/
--   Sparziels) als Folge-Zeile der Vorgaenger-Kette (Audit Paket 2, Punkt 1). Vorher setzte die Reaktivierung nur
--   status='active' auf die beendete Zeile -> "aktiv", aber nie wieder faellig. valid_to einfach zu leeren waere
--   falsch: die Vorkommen der Luecke (Schliessen .. Reaktivieren) wuerden im 90-Tage-Fenster nachtraeglich faellig.
--   Neue Zeile: alle Felder geerbt (Konto, Ziel-Konto, Betrag, Kadenz, Abbuchungstag, Anker first_payment_date ->
--   gleiches Raster), status='active', valid_from = p_from (fruehestens der Tag NACH dem letzten gebuchten/
--   uebersprungenen Vorkommen der Kette -> nie doppelt faellig), valid_to = NULL, predecessor_id = alte Zeile;
--   Besitzer zeigen danach auf die neue Zeile (fn_repoint_recurring_owners). Gerufen von fn_set_savings_plan und
--   fn_set_savings_goal (Status -> active).
--   KORRIGIERBAR (kein Write) -> {ok:false, reason}: Zeile noch nicht beendet (valid_to NULL oder nach p_from);
--   Zeile hat schon einen Nachfolger (nur der Kopf der Kette ist reaktivierbar).
--   RUECKGABE: {ok:true, recurring_payment_id} (neue Zeile).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reopen_recurring_payment(p_rp_id int, p_from date)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_old    finance.recurring_payments%ROWTYPE;
    v_new_id INT;
    v_from   DATE;
BEGIN
    SELECT * INTO v_old FROM finance.recurring_payments WHERE id = p_rp_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', p_rp_id;
    END IF;

    IF v_old.valid_to IS NULL OR v_old.valid_to > p_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This payment has not ended on ' || p_from || '; resume it instead of reopening it.');
    END IF;
    IF EXISTS (SELECT 1 FROM finance.recurring_payments WHERE predecessor_id = p_rp_id) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This payment was already continued by a newer entry; change that entry instead.');
    END IF;

    -- Nie vor oder an einem schon gebuchten/uebersprungenen Vorkommen der Kette beginnen (Review: Schliessen und
    -- Reaktivieren am Ausfuehrungstag haette dasselbe Vorkommen unter der neuen rp-id erneut faellig gemacht).
    SELECT GREATEST(p_from, max(d) + 1) INTO v_from FROM (
        SELECT max(t.recurring_due_date) AS d FROM finance.transactions t
        WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
        UNION ALL
        SELECT max(s.due_date) FROM finance.recurring_payment_skips s
        WHERE s.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
    ) x;
    v_from := COALESCE(v_from, p_from);

    v_new_id := finance.fn_add_recurring_payment(
        v_old.account_id, v_old.amount, v_old.name, v_old.schedule_interval, v_old.schedule_unit,
        v_old.schedule_day_of_month, v_old.first_payment_date, v_from, NULL, 'active', v_old.notes);

    -- Transfer-Ziel, Vorgaenger-Link und feste Monatstage erben (sonst kaeme ein 4-Tage-Plan still als 1x/Monat zurueck)
    UPDATE finance.recurring_payments
    SET target_account_id = v_old.target_account_id, predecessor_id = p_rp_id,
        schedule_days_of_month = v_old.schedule_days_of_month
    WHERE id = v_new_id;
    PERFORM finance.fn_repoint_recurring_owners(p_rp_id, v_new_id);

    RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_new_id);
END;
$$;
