-- ============================================================
-- fn_change_owned_recurring (INTERNAL HELPER — not tool-facing, WP2 "Finanzen schlank")
--   Die EINE Aenderung von Betrag/Rhythmus/Abbuchungstag einer entitaets-besessenen Raten-Kette (Kredit, Versicherung;
--   zweiter Konsument -> vereinheitlicht). Vorher ueberschrieben fn_set_loan/fn_set_insurance die rp in place: die
--   Historie war weg, und ein neuer Abbuchungstag verschob das Raster schon gebuchter Termine (alte Termine erschienen
--   wieder offen).
--   * KORREKTUR (in place, keine Historie zu bewahren): der Kopf hat noch keinen gebuchten/uebersprungenen Termin, vor
--     heute war noch keiner faellig, und kein spaeterer Stichtag ist genannt (p_eff_from leer oder <= valid_from).
--   * SONST Split ueber fn_split_recurring_payment (Historie, Kopf-Repoint, Guards dort) zum Stichtag p_eff_from, Default
--     = naechster noch nicht erledigter Termin ab heute (fn_recurring_next_due).
--   Positionale Args: p_amount signed (NULL = unveraendert), p_interval/p_unit/p_dom (NULL = unveraendert; ein neuer
--   Einzeltag ersetzt feste Monatstage).
--   RUECKGABE: {ok:true, recurring_payment_id (Kopf danach), split, previous_id (nur Split), effective_from}
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
BEGIN
    SELECT * INTO v_head FROM finance.recurring_payments
     WHERE id = finance.fn_recurring_lineage_head(p_rp_id) FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', p_rp_id;
    END IF;

    IF finance.fn_recurring_last_done(v_head.id) IS NULL
       AND (p_eff_from IS NULL OR p_eff_from <= v_head.valid_from)
       AND NOT EXISTS (SELECT 1 FROM finance.fn_schedule_occurrences(
               v_head.first_payment_date, v_head.schedule_interval, v_head.schedule_unit, v_head.schedule_day_of_month,
               v_head.schedule_days_of_month, v_head.valid_from, v_today - 1)) THEN
        UPDATE finance.recurring_payments SET
            amount                 = COALESCE(p_amount, amount),
            schedule_interval      = COALESCE(p_interval, schedule_interval),
            schedule_unit          = COALESCE(p_unit, schedule_unit),
            schedule_day_of_month  = COALESCE(p_dom, schedule_day_of_month),
            schedule_days_of_month = CASE WHEN p_dom IS NOT NULL OR COALESCE(p_unit, schedule_unit) <> 'month'
                                          THEN NULL ELSE schedule_days_of_month END
        WHERE id = v_head.id;
        RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_head.id, 'split', false,
                                  'effective_from', v_head.valid_from);
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
                              'previous_id', v_head.id, 'effective_from', v_eff);
END;
$$;
