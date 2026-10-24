-- ============================================================
-- fn_set_insurance (ATOMIC WRITE) -- einziges set_*-Tool mit Recurring-Sync (Befund B)
--   Aendert eine bestehende Versicherung (Praemie/Schedule/Kuendigung/Police). Partielles Update.
--   monthly_equivalent (GENERATED ÷12) rechnet auto.
--   RECURRING-SYNC (In-Place, FK bleibt intakt -- KEIN Validity-Split bei entitaets-besessenen Zeilen):
--     - Praemie/Schedule geaendert -> verknuepfte recurring_payment.amount/schedule_* mit-setzen. Der
--       Beitrag je Abbuchung wird HIER aus den gemergten Werten abgeleitet (fn_insurance_period_amount,
--       wie im Create); ein mitgeliefertes recurring_amount wird ignoriert.
--     - valid_to kommt als LETZTER Vertragstag (inklusiv) und wird als exklusives Ende (Folgetag) gespeichert.
--     - valid_to (Vertragsende) wird IMMER in die recurring_payment gespiegelt -> der Beitrag endet im
--       Cashflow/Scheduler mit dem Vertrag (active_recurring_payments filtert valid_to).
--     - status in ('cancelled','expired') -> recurring valid_to = Kuendigungsdatum (Fallback valid_to/
--       CURRENT_DATE); 'paused' NUR, wenn dieses Datum erreicht ist — eine Kuendigung zum kuenftigen
--       Vertragsende laesst die Beitraege bis dahin laufen. status='active' -> recurring wieder 'active'.
--   Eingabe jsonb: insurance_id (im n8n via fn_resolve_insurance aufgeloest), name,
--   insurance_company, policy_number, policyholder_person_id (Slug; leer=unveraendert), annual_premium, schedule_interval,
--   schedule_unit, schedule_day_of_month, valid_to, status, notes,
--   insurance_type/beneficiary/coverage_amount/claim_deadline_hours (WS-0b estate: partielles Update der
--   Nachlass-Felder, geschlossene insurance_type-Liste per CHECK; leer=unveraendert).
--   Rohwerte (Praemie/Summe mit Tausenderpunkt, Meldefrist, Rhythmus, insurance_type) liest + prueft
--   fn_insurance_fields — dieselbe fn wie fn_create_insurance und die Karten-Vorschau.
--   RUECKGABE: {ok:true, insurance_id, recurring_payment_id}. Korrigierbar (annual_premium<=0, Betrag unlesbar,
--   status/schedule_unit/insurance_type unbekannt, coverage_amount<0, Meldefrist ungueltig) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_insurance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id       INT     := (p->>'insurance_id')::int;
    v_premium  NUMERIC;
    v_coverage NUMERIC;
    v_deadline INT;
    v_fields   JSONB;
    v_reason   TEXT;
    v_status   finance.insurance_status;   -- Casts erst nach dem Enum-Guard (Import-Haertung)
    v_rec_amt  NUMERIC;
    v_end      DATE;
    v_valid_to DATE    := NULLIF(p->>'valid_to', '')::date;
    v_interval SMALLINT := NULLIF(p->>'schedule_interval', '')::smallint;
    v_unit     finance.schedule_unit;
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_rp       INT;
    v_vfrom    DATE;
BEGIN
    v_reason := finance.fn_enum_reason('finance.insurance_status'::regtype, p->>'status', 'status');
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Rohwerte lesen + pruefen: EINE Adresse mit fn_create_insurance und der Karten-Vorschau (fn_insurance_fields).
    v_fields := finance.fn_insurance_fields(p);
    IF (v_fields->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_fields;
    END IF;
    v_premium  := (v_fields->>'annual_premium')::numeric;
    v_coverage := (v_fields->>'coverage_amount')::numeric;
    v_deadline := (v_fields->>'claim_deadline_hours')::int;
    v_status   := NULLIF(p->>'status', '')::finance.insurance_status;
    v_unit     := NULLIF(p->>'schedule_unit', '')::finance.schedule_unit;
    -- WP-2b: fester Buchungstag muss 1-28 oder -1 (Monatsletzter) sein (29/30/31 overflowen kurze Monate).
    IF NOT finance.fn_valid_schedule_dom(v_dom) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Booking day ' || v_dom || ' is invalid - allowed are 1-28 or -1 (last day of the month); '
                   || 'for the 29th/30th/31st use -1 (last day of the month).');
    END IF;
    SELECT recurring_payment_id, valid_from INTO v_rp, v_vfrom FROM finance.insurances WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Insurance % not found.', v_id;
    END IF;

    -- Korrigierbar: Jahrespraemie muss positiv sein.
    IF v_premium IS NOT NULL AND v_premium <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Annual premium must be a positive number, got ' || v_premium || '.');
    END IF;

    -- Korrigierbar: Kuendigungs-/Enddatum darf nicht vor dem Vertragsbeginn liegen.
    IF v_valid_to IS NOT NULL AND v_valid_to < v_vfrom THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'valid_to (' || v_valid_to || ') must not be before the policy start valid_from (' || v_vfrom || ').',
            'valid_from', v_vfrom);
    END IF;
    -- Eingabe = LETZTER Vertragstag (inklusiv, wie vom Nutzer genannt); gespeichert wird das exklusive Ende
    -- (Konvention [valid_from, valid_to) aller Views/close_*/Split) — die fn rechnet um, nicht das LLM.
    v_valid_to := v_valid_to + 1;

    UPDATE finance.insurances SET
        name                  = COALESCE(NULLIF(p->>'name', ''), name),
        insurance_company     = COALESCE(NULLIF(p->>'insurance_company', ''), insurance_company),
        policy_number         = COALESCE(NULLIF(p->>'policy_number', ''), policy_number),
        policyholder_person_id = COALESCE(NULLIF(p->>'policyholder_person_id', ''), policyholder_person_id),  -- WS-4: typisierter Versicherungsnehmer (Slug); leer=unveraendert
        annual_premium        = COALESCE(v_premium, annual_premium),
        schedule_interval     = COALESCE(v_interval, schedule_interval),
        schedule_unit         = COALESCE(v_unit, schedule_unit),
        schedule_day_of_month = COALESCE(v_dom, schedule_day_of_month),
        valid_to              = COALESCE(v_valid_to, valid_to),
        status                = COALESCE(v_status, status),
        notes                 = COALESCE(NULLIF(p->>'notes', ''), notes),
        -- WS-0b (estate): partielles Update der Nachlass-Felder (leer=unveraendert; type-CHECK = Backstop).
        insurance_type        = COALESCE(NULLIF(p->>'insurance_type', ''), insurance_type),
        beneficiary           = COALESCE(NULLIF(p->>'beneficiary', ''), beneficiary),
        coverage_amount       = COALESCE(v_coverage, coverage_amount),
        claim_deadline_hours  = COALESCE(v_deadline, claim_deadline_hours)
    WHERE id = v_id;

    IF v_rp IS NOT NULL THEN
        -- Betrag aus den GEMERGTEN Werten ableiten (eine reine Praemien-Aenderung nutzt den bestehenden Rhythmus).
        IF v_premium IS NOT NULL OR v_interval IS NOT NULL OR v_unit IS NOT NULL THEN
            SELECT -finance.fn_insurance_period_amount(annual_premium, schedule_interval, schedule_unit)
            INTO v_rec_amt FROM finance.insurances WHERE id = v_id;
        END IF;
        -- Betrag/Schedule der verknuepften recurring_payment mit-syncen (nur wenn etwas geliefert wurde).
        IF v_rec_amt IS NOT NULL OR v_dom IS NOT NULL THEN
            UPDATE finance.recurring_payments SET
                amount                = COALESCE(v_rec_amt, amount),
                schedule_interval     = COALESCE(v_interval, schedule_interval),
                schedule_unit         = COALESCE(v_unit, schedule_unit),
                schedule_day_of_month = COALESCE(v_dom, schedule_day_of_month)
            WHERE id = v_rp;
        END IF;

        -- Vertragsende immer spiegeln (auch ohne Statuswechsel).
        IF v_valid_to IS NOT NULL THEN
            UPDATE finance.recurring_payments SET valid_to = v_valid_to WHERE id = v_rp;
        END IF;

        -- Deaktivierungs-Kaskade: Kuendigung/Ablauf -> Beitrag verlaesst den Cashflow ab dem Enddatum.
        IF v_status IN ('cancelled', 'expired') THEN
            SELECT COALESCE(v_valid_to, valid_to, CURRENT_DATE) INTO v_end FROM finance.insurances WHERE id = v_id;
            UPDATE finance.recurring_payments
            SET valid_to = v_end,
                status   = CASE WHEN v_end <= CURRENT_DATE THEN 'paused' ELSE status END
            WHERE id = v_rp;
        ELSIF v_status = 'active' THEN
            UPDATE finance.recurring_payments SET status = 'active' WHERE id = v_rp;
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'insurance_id', v_id, 'recurring_payment_id', v_rp);
END;
$$;
