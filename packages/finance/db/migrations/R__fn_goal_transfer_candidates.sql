-- ============================================================
-- fn_goal_transfer_candidates (READ HELPER — Livebefund 2026-10-27)
--   Freistehende Dauerauftraege (interne Transfers), die schon in den Topf p_pot eines Sparziels fliessen, optional nur
--   vom Abbuchungskonto p_debit. Eine Adresse fuer den Guard existing_transfer in fn_create_savings_goal und
--   fn_set_savings_goal (eine neue Ziel-Rate neben einem bestehenden Dauerauftrag zaehlte doppelt; der Agent hatte ihn
--   deshalb geloescht und die Rate ohne Tag neu angelegt) und fuer den Import.
--   Kandidat = Kopf seiner Kette (fn_recurring_lineage_head), keiner Entitaet gehoerend (fn_recurring_owner NULL),
--   status active, nicht beendet (valid_to NULL oder > heute; ein kuenftiger Start zaehlt), amount < 0 (Quelle).
--   replaceable = monatlich mit hoechstens einem Tag (month/1, keine festen Tage) -> eine Ziel-Rate (immer monatlich)
--   kann ihn nahtlos fortfuehren; day = sein Abbuchungstag (NULL = Tag der ersten Ausfuehrung), next_due = naechster
--   offener Termin (fn_recurring_next_due).
--   plpgsql (late-bound): fn_recurring_owner/fn_recurring_next_due sortieren alphabetisch spaeter.
--   RUECKGABE: jsonb-Array [{id, name, account_id, amount (>0, je Ausfuehrung), monthly_amount, currency, rhythm, day,
--   replaceable, next_due}] nach id; leer = '[]'.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_transfer_candidates(p_pot int, p_debit int)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'id', r.id,
                   'name', r.name,
                   'account_id', r.account_id,
                   'amount', abs(r.amount),
                   'monthly_amount', abs(r.monthly_equivalent),
                   'currency', a.currency,
                   'rhythm', finance.fn_schedule_label(r.schedule_unit, r.schedule_interval, r.schedule_day_of_month,
                                                       r.schedule_days_of_month),
                   'day', r.schedule_day_of_month,
                   'replaceable', r.schedule_unit = 'month' AND r.schedule_interval = 1 AND r.schedule_days_of_month IS NULL,
                   'next_due', finance.fn_recurring_next_due(r.id, current_date))
               ORDER BY r.id)
        FROM finance.recurring_payments r
        JOIN finance.accounts a ON a.id = r.account_id
        WHERE r.target_account_id = p_pot
          AND r.amount < 0
          AND r.status = 'active'
          AND (r.valid_to IS NULL OR r.valid_to > current_date)
          AND (p_debit IS NULL OR r.account_id = p_debit)
          AND finance.fn_recurring_lineage_head(r.id) = r.id
          AND finance.fn_recurring_owner(r.id) IS NULL), '[]'::jsonb);
END;
$$;
