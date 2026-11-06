-- ============================================================
-- fn_split_recurring_payment (INTERNAL HELPER — not tool-facing)
--   Der EINE history-erhaltende Validity-Split einer recurring_payment (Audit F2). Gerufen von
--   fn_set_recurring_payment und fn_set_savings_plan (zweiter Konsument -> vereinheitlicht).
--   Alte Zeile endet zum Stichtag (valid_to = p_eff_from, EXKLUSIV); neue Zeile gilt ab p_eff_from und ERBT
--   von der alten: account_id, target_account_id (Transfer bleibt Transfer), status (pausiert bleibt
--   pausiert), das bisherige Ende (wenn kein neues), den Rhythmus-Anker first_payment_date (bei gleicher
--   Kadenz; sonst Neu-Anker am Stichtag). Vorkommen vor valid_from blendet fn_recurring_due_open aus ->
--   am Stichtag ist nie alte UND neue Rate faellig.
--   Positionale Args (fn-intern): p_amount signed (NULL = alter Betrag), p_interval/p_unit/p_dom/p_name/p_notes
--   (NULL = alter Wert), p_valid_to = neues Ende EXKLUSIV gespeichert (Aufrufer rechnet die inklusive
--   Nutzer-Eingabe +1 Tag um; NULL = altes Ende).
--   VORGAENGER-KETTE (Audit Paket 2, A0): die neue Zeile traegt predecessor_id = alte Zeile; alle Besitzer
--   (Kredit/Sparplan/Sparziel/Versicherung/Vorsorge) zeigen danach auf die neue Zeile (fn_repoint_recurring_owners,
--   Kopf-Regel). Alte Vorkommen vor dem Stichtag bleiben auf der alten Zeile und werden ueber
--   fn_recurring_lineage weiter ihrem Besitzer zugeordnet.
--   KORRIGIERBAR (kein Write) -> {ok:false, reason, ...}: Stichtag nicht nach valid_from; alte Zeile vor dem
--   Stichtag schon beendet; Stichtag nicht nach der letzten gebuchten/uebersprungenen Rate (sonst gaelten
--   Vorkommen doppelt; "gebucht" keyt auf die Faelligkeit recurring_due_date, nicht aufs Buchungsdatum);
--   neues Ende nicht nach dem Stichtag.
--   FESTE MONATSTAGE p_days (optional, letzter Parameter): NULL = von der alten Zeile erben, solange die Einheit
--   'month' bleibt und kein neuer Einzeltag p_dom kommt; '{}' = leeren; sonst die neuen Tage (der Einzeltag wird
--   dann NULL, CHECK finance_rp_schedule_days_chk). Andere Tage = Kadenzwechsel -> Neu-Anker am Stichtag.
--   RUECKGABE: {ok:true, recurring_payment_id} (neue Zeile).
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_split_recurring_payment(int, date, numeric, smallint, finance.schedule_unit, smallint, text, text, date);
CREATE OR REPLACE FUNCTION finance.fn_split_recurring_payment(
    p_rp_id     int,
    p_eff_from  date,
    p_amount    numeric,
    p_interval  smallint,
    p_unit      finance.schedule_unit,
    p_dom       smallint,
    p_name      text,
    p_notes     text,
    p_valid_to  date,
    p_days      smallint[] DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_old      finance.recurring_payments%ROWTYPE;
    v_last     DATE;
    v_interval SMALLINT;
    v_unit     finance.schedule_unit;
    v_days     SMALLINT[];
    v_dom      SMALLINT;
    v_new_id   INT;
BEGIN
    SELECT * INTO v_old FROM finance.recurring_payments WHERE id = p_rp_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', p_rp_id;
    END IF;

    IF p_eff_from <= v_old.valid_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Effective date (' || p_eff_from || ') must be after the current entry valid_from (' || v_old.valid_from || ').',
            'current_valid_from', v_old.valid_from);
    END IF;
    IF v_old.valid_to IS NOT NULL AND v_old.valid_to <= p_eff_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This payment already ended (last valid day ' || (v_old.valid_to - 1)
                   || ') before the effective date ' || p_eff_from || '; create a new payment instead.',
            'last_valid_day', v_old.valid_to - 1);
    END IF;

    SELECT max(d) INTO v_last FROM (
        SELECT max(recurring_due_date) AS d FROM finance.transactions WHERE recurring_payment_id = p_rp_id
        UNION ALL
        SELECT max(due_date) FROM finance.recurring_payment_skips WHERE recurring_payment_id = p_rp_id
    ) x;
    IF v_last IS NOT NULL AND p_eff_from <= v_last THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The payment due on ' || v_last || ' is already booked or skipped at the old terms; '
                   || 'choose an effective date after ' || v_last || '.',
            'last_booked', v_last);
    END IF;

    IF p_valid_to IS NOT NULL AND p_valid_to <= p_eff_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The end date (last valid day ' || (p_valid_to - 1) || ') must not be before the effective date '
                   || p_eff_from || '.');
    END IF;

    v_interval := COALESCE(p_interval, v_old.schedule_interval);
    v_unit     := COALESCE(p_unit, v_old.schedule_unit);
    -- Feste Monatstage: neue Liste > geerbte (nur bei month ohne neuen Einzeltag) ; Tage und Einzeltag schliessen sich aus
    v_days := CASE WHEN v_unit <> 'month' THEN NULL
                   WHEN p_days IS NOT NULL THEN NULLIF(p_days, '{}')
                   WHEN p_dom IS NOT NULL THEN NULL
                   ELSE v_old.schedule_days_of_month END;
    v_dom  := CASE WHEN v_days IS NOT NULL THEN NULL ELSE COALESCE(p_dom, v_old.schedule_day_of_month) END;

    UPDATE finance.recurring_payments SET valid_to = p_eff_from WHERE id = p_rp_id;

    v_new_id := finance.fn_add_recurring_payment(
        v_old.account_id,
        COALESCE(p_amount, v_old.amount),
        COALESCE(NULLIF(p_name, ''), v_old.name),
        v_interval,
        v_unit,
        v_dom,
        CASE WHEN v_interval = v_old.schedule_interval AND v_unit = v_old.schedule_unit
                  AND v_days IS NOT DISTINCT FROM v_old.schedule_days_of_month
             THEN v_old.first_payment_date ELSE p_eff_from END,
        p_eff_from,
        COALESCE(p_valid_to, v_old.valid_to),
        v_old.status,
        COALESCE(NULLIF(p_notes, ''), v_old.notes));

    -- Transfer bleibt Transfer + Vorgaenger-Link + feste Monatstage (fn_add_recurring_payment-Signatur bewusst
    -- unveraendert; No-Self-Transfer- und Tage-CHECK sind zeilenweise und durch die geerbten Werte erfuellt).
    UPDATE finance.recurring_payments
    SET target_account_id = v_old.target_account_id, predecessor_id = p_rp_id, schedule_days_of_month = v_days
    WHERE id = v_new_id;
    PERFORM finance.fn_repoint_recurring_owners(p_rp_id, v_new_id);

    RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_new_id);
END;
$$;
