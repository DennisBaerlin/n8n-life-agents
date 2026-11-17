-- ============================================================
-- fn_change_owned_recurring (INTERNAL HELPER — not tool-facing)
--   Die eine Aenderung von Betrag/Rhythmus/Abbuchungstag einer entitaets-besessenen Raten-Kette (Kredit, Versicherung, Vorsorge;
--   Konsumenten fn_set_loan, fn_set_insurance, fn_set_pension, fn_set_savings_goal). Ein In-place-Ueberschreiben verloere die Historie, und ein neuer
--   Abbuchungstag verschoebe das Raster schon gebuchter Termine (alte Termine erschienen wieder offen).
--   * Korrektur (in place, keine Historie zu bewahren): der Kopf hat noch keinen gebuchten/uebersprungenen Termin, vor
--     heute war noch keiner faellig, und kein spaeterer Stichtag ist genannt (p_eff_from leer oder <= valid_from).
--     Gleiches gilt fuer einen Kopf, der selbst noch unberuehrt ist, waehrend fruehere Glieder Historie tragen (geplante
--     Aenderung, frisch reaktivierte Zahlung): leer oder genau sein Start -> der Kopf wird ersetzt, die Glieder davor
--     bleiben; ein Split am eigenen Start waere unmoeglich. Ein Stichtag vor seinem Start geht in den Split-Guard.
--   * Sonst Split ueber fn_split_recurring_payment (Historie, Kopf-Repoint, Guards dort) zum Stichtag p_eff_from, Default
--     = naechster noch nicht erledigter Termin ab heute (fn_recurring_next_due).
--   Positionale Args: p_amount signed (NULL = unveraendert), p_interval/p_unit/p_dom (NULL = unveraendert; ein neuer
--     Einzeltag ersetzt feste Monatstage).
--   Neuer Abbuchungstag bei gleicher Kadenz: jeder Monat behaelt genau einen Termin (in place fn_recurring_reanchor_day, im Split
--     fn_recurring_day_shift); effective_from ist der gespeicherte Start der Zeile mit den neuen Bedingungen.
--   Rueckgabe: {ok:true, recurring_payment_id (Kopf danach), split, previous_id (nur Split), effective_from}
--   | {ok:false, reason, ...} aus den Split-Guards bzw. ohne kommenden Termin.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_change_owned_recurring(
    p_rp_id    int,
    p_eff_from date,
    p_amount   numeric,
    p_interval smallint,
    p_unit     finance.schedule_unit,
    p_dom      smallint
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_head  finance.recurring_payments%ROWTYPE;
    v_today DATE := core.fn_today();
    v_eff   DATE;
    v_res   JSONB;
    v_done  DATE;
BEGIN
    SELECT * INTO v_head FROM finance.recurring_payments
     WHERE id = finance.fn_recurring_lineage_head(p_rp_id) FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', p_rp_id;
    END IF;

    v_done := finance.fn_recurring_last_done(v_head.id);
    IF ((v_done IS NULL AND (p_eff_from IS NULL OR p_eff_from <= v_head.valid_from))
        OR (v_done < v_head.valid_from AND (p_eff_from IS NULL OR p_eff_from = v_head.valid_from)))
       AND NOT EXISTS (SELECT 1 FROM finance.fn_schedule_occurrences(
               v_head.first_payment_date, v_head.schedule_interval, v_head.schedule_unit, v_head.schedule_day_of_month,
               v_head.schedule_days_of_month, v_head.valid_from, v_today - 1)) THEN
        -- Nur ein neuer Tag (gleiche Kadenz): Start und Anker ziehen auf den neuen Tag im Startmonat mit, sonst fiele der
        -- erste Termin weg (fn_recurring_reanchor_day; ein Kadenzwechsel behaelt den alten Weg)
        IF COALESCE(p_unit, v_head.schedule_unit) = v_head.schedule_unit
           AND COALESCE(p_interval, v_head.schedule_interval) = v_head.schedule_interval THEN
            PERFORM finance.fn_recurring_reanchor_day(v_head.id, p_dom);
        END IF;
        UPDATE finance.recurring_payments SET
            amount                 = COALESCE(p_amount, amount),
            schedule_interval      = COALESCE(p_interval, schedule_interval),
            schedule_unit          = COALESCE(p_unit, schedule_unit),
            schedule_day_of_month  = COALESCE(p_dom, schedule_day_of_month),
            schedule_days_of_month = CASE WHEN p_dom IS NOT NULL OR COALESCE(p_unit, schedule_unit) <> 'month'
                                          THEN NULL ELSE schedule_days_of_month END
        WHERE id = v_head.id;
        RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_head.id, 'split', false,
                                  'effective_from', (SELECT r.valid_from FROM finance.recurring_payments r WHERE r.id = v_head.id));
    END IF;

    v_eff := COALESCE(p_eff_from, finance.fn_recurring_next_due(v_head.id, v_today));
    IF v_eff IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'No upcoming due date was found for this payment - give the date of the first payment with the new terms (effective_from).');
    END IF;
    v_res := finance.fn_split_recurring_payment(v_head.id, v_eff, p_amount, p_interval, p_unit, p_dom, NULL, NULL, NULL);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_res;
    END IF;
    RETURN jsonb_build_object('ok', true, 'recurring_payment_id', (v_res->>'recurring_payment_id')::int, 'split', true,
                              'previous_id', v_head.id,
                              -- der echte Stichtag: ein neuer Tag kann ihn verschieben (fn_recurring_day_shift im Split)
                              'effective_from', (SELECT r.valid_from FROM finance.recurring_payments r
                                                  WHERE r.id = (v_res->>'recurring_payment_id')::int));
END;
$$;
