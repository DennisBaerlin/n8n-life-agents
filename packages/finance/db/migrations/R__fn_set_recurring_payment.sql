-- ============================================================
-- fn_set_recurring_payment (ATOMIC WRITE) -- nur STANDALONE-Zeilen
--   Aendert eine standalone wiederkehrende Einnahme/Ausgabe (Gehalt/Miete/Abo/Rente).
--   STANDALONE-GUARD (Befund B): ist die Zeile von einer Entitaet besessen (insurance/loan/
--   savings_goal/pension -> recurring_payment_id), wird abgelehnt ({ok:false}) -> Aenderung
--   ueber das jeweilige set_<entity>-Tool (sonst Verwaisen der FK beim Split).
--   BETRAGS-AENDERUNG = history-erhaltender VALIDITY-SPLIT (Best Practice "effective date") ueber den
--   gemeinsamen Helfer fn_split_recurring_payment (Vorzeichen aus der alten Zeile; Ziel-Konto, Status, Ende,
--   Rhythmus-Anker geerbt; Guards s. dort). Sonst (kein amount) IN-PLACE: status (pause/resume),
--   valid_to (beenden), name, schedule_day_of_month, notes.
--   valid_to-EINGABE ist INKLUSIV (letzter gueltiger Tag, wie der Nutzer es sagt); gespeichert wird
--   EXKLUSIV (+1 Tag, Konvention [valid_from, valid_to) -> Audit F2a). Das LLM rechnet nicht.
--   Eingabe jsonb: recurring_payment_id (im n8n aufgeloest), amount (positiver Betrag -> Split),
--   valid_from (Stichtag des Splits; default heute), status, valid_to, schedule_day_of_month,
--   name, notes.
--   RUECKGABE: {ok:true, recurring_payment_id, split}; bei split=true zusaetzlich previous_id. Korrigierbar (entitaets-besessen,
--   amount<=0, Split-Guards des Helfers inkl. last_booked) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_recurring_payment(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id       INT      := (p->>'recurring_payment_id')::int;
    v_amount   NUMERIC  := NULLIF(p->>'amount', '')::numeric;   -- positiver Magnitude-Betrag
    v_from     DATE     := NULLIF(p->>'valid_from', '')::date;  -- Stichtag fuer den Split
    v_status   finance.payment_status := NULLIF(p->>'status', '')::finance.payment_status;
    v_to       DATE     := NULLIF(p->>'valid_to', '')::date + 1;   -- inklusive Eingabe -> exklusiv gespeichert
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_row      finance.recurring_payments%ROWTYPE;
    v_owner    TEXT;
    v_signed   NUMERIC;
    v_new_id   INT;
    v_eff_from DATE;
    v_core     JSONB;     -- Phase L WS-3: Erfolgs-Kern beider Zweige (Split/In-Place) vor dem Cashflow-Fold
BEGIN
    -- WP-2b: fester Buchungstag muss 1-28 oder -1 (Monatsletzter) sein (29/30/31 overflowen kurze Monate).
    IF NOT finance.fn_valid_schedule_dom(v_dom) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Booking day ' || v_dom || ' is invalid - allowed are 1-28 or -1 (last day of the month); '
                   || 'for the 29th/30th/31st use -1 (last day of the month).');
    END IF;
    SELECT * INTO v_row FROM finance.recurring_payments WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', v_id;
    END IF;

    -- Standalone-Guard (Befund B): entitaets-besessene Zeilen -> ueber das set_<entity>-Tool.
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM finance.insurances    WHERE recurring_payment_id = v_id) THEN 'insurance'
        WHEN EXISTS (SELECT 1 FROM finance.loans         WHERE recurring_payment_id = v_id) THEN 'loan'
        WHEN EXISTS (SELECT 1 FROM finance.savings_goals WHERE recurring_payment_id = v_id) THEN 'savings goal'
        WHEN EXISTS (SELECT 1 FROM finance.pension       WHERE recurring_payment_id = v_id) THEN 'pension'
        WHEN EXISTS (SELECT 1 FROM finance.savings_plans WHERE recurring_payment_id = v_id) THEN 'savings plan'
        ELSE NULL END
    INTO v_owner;
    IF v_owner IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This recurring payment belongs to a ' || v_owner || '; change it via that entity set tool, not directly.');
    END IF;

    IF v_amount IS NOT NULL THEN
        -- BETRAGS-AENDERUNG -> Validity-Split
        IF v_amount <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'Amount must be a positive number, got ' || v_amount || '.');
        END IF;
        v_eff_from := COALESCE(v_from, CURRENT_DATE);
        -- Vorzeichen aus der bestehenden Zeile uebernehmen (+ Einnahme / - Ausgabe).
        v_signed := (CASE WHEN v_row.amount < 0 THEN -1 ELSE 1 END) * v_amount;
        -- Validity-Split ueber den gemeinsamen Helfer (Guards + Vererbung dort; {ok:false} = kein Write).
        v_core := finance.fn_split_recurring_payment(
            v_id, v_eff_from, v_signed, NULL, NULL, v_dom, NULLIF(p->>'name', ''), NULLIF(p->>'notes', ''), v_to);
        IF (v_core->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_core;
        END IF;
        v_new_id := (v_core->>'recurring_payment_id')::int;
        -- Ein mitgenannter Status gilt fuer die NEUE Zeile ("laeuft wieder, ab 1.11. 3200"); sonst erbt sie den alten.
        IF v_status IS NOT NULL THEN
            UPDATE finance.recurring_payments SET status = v_status WHERE id = v_new_id;
        END IF;
        v_core := jsonb_build_object('ok', true, 'recurring_payment_id', v_new_id, 'split', true, 'previous_id', v_id);
    ELSE
        -- IN-PLACE-Aenderung (kein Betrag)
        UPDATE finance.recurring_payments SET
            name                  = COALESCE(NULLIF(p->>'name', ''), name),
            status                = COALESCE(v_status, status),
            valid_to              = COALESCE(v_to, valid_to),
            schedule_day_of_month = COALESCE(v_dom, schedule_day_of_month),
            notes                 = COALESCE(NULLIF(p->>'notes', ''), notes)
        WHERE id = v_id;
        v_core := jsonb_build_object('ok', true, 'recurring_payment_id', v_id, 'split', false);
    END IF;

    -- Phase L WS-3: Cashflow-Sofort-Hinweis (Event-Fold, geteilt von beiden Erfolgs-Zweigen). Post-State NACH dem
    -- Write aus monthly_cashflow_summary. M3 (Stichtag-Grenze): bei ZUKUENFTIG datierter Erhoehung bleibt die ALTE
    -- Zeile aktiv (valid_to=Stichtag>heute -> view-Filter valid_to>current_date erfasst sie weiter) und die NEUE ist
    -- noch nicht gueltig (valid_from>current_date -> raus) -> die Live-View zeigt den noch geltenden Ist-Stand, der
    -- Fold feuert korrekterweise JETZT NICHT; der periodische Cron faengt es, wenn der Stichtag erreicht ist. Bei
    -- Stichtag HEUTE spiegelt die View exakt die neue Zeile. Audit Paket 3: der eine Fold-Helfer
    -- fn_cashflow_coverage_fold (Pflichtausgaben > Einnahmen, gelatcht, Re-Arm bei Erholung; geteilt mit
    -- fn_create_recurring_payment) -> Note (advisory, nicht-blockierend).
    RETURN v_core || finance.fn_cashflow_coverage_fold();
END;
$$;
