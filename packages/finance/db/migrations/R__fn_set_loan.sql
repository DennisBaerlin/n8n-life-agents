-- ============================================================
-- fn_set_loan (ATOMIC WRITE)
--   Aendert Konditionen/Status eines bestehenden Kredits (Zinsbindungs-Ende: neuer Zins/Tilgung/
--   Annuitaet; Status). Partielles Update. Zins/Tilgung je Rate liefert finance.loan_overview LIVE aus der
--   Restschuld (principal_rate ist nur informativ; die Ursprungs-GENERATED-Spalten entfielen mit finance:V025).
--   RECURRING-SYNC (Befund B, in-place): geaenderte monthly_annuity -> verknuepfte Kreditrate
--   (recurring_payment.amount = -annuity); geaenderter schedule_day_of_month -> verknuepfte Kreditrate
--   (recurring_payment.schedule_day_of_month).
--   STATUS-KASKADE: paused/paid_off/refinanced -> verknuepfte recurring_payment 'paused'; active -> 'active'.
--   NICHT abgebildet: der mehrschrittige Umschuldungs-Flow (neues Konto + Settlement-Buchung + neuer
--   Kredit) -- set_loan aendert nur Konditionen/Status der bestehenden Zeile.
--   Eingabe jsonb: loan_id (im n8n aufgeloest), name, lender, borrower_person_id (Slug; leer=unveraendert), interest_rate, principal_rate,
--   interest_rate_fixed_until, monthly_annuity, schedule_day_of_month, status, notes.
--   RUECKGABE: {ok:true, loan_id, recurring_payment_id}. Korrigierbar (neg. Rate, annuity<=0,
--   active-ohne-Annuitaet, unbekannter status, wirksame Rate unter dem Monatszins der Restschuld -> {interest, payment};
--   jede Buchung scheiterte sonst an fn_get_loan_payment_split) -> {ok:false} OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_loan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id          INT      := (p->>'loan_id')::int;
    v_irate       NUMERIC  := NULLIF(p->>'interest_rate', '')::numeric;
    v_prate       NUMERIC  := NULLIF(p->>'principal_rate', '')::numeric;
    v_annuity     NUMERIC  := NULLIF(p->>'monthly_annuity', '')::numeric;
    v_status      finance.loan_status;   -- Cast erst nach dem Enum-Guard (Import-Haertung)
    v_reason      TEXT     := finance.fn_enum_reason('finance.loan_status'::regtype, p->>'status', 'status');
    v_dom         SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_loan        finance.loans%ROWTYPE;
    v_eff_status  finance.loan_status;
    v_eff_annuity NUMERIC;
    v_interest    NUMERIC;
BEGIN
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_status := NULLIF(p->>'status', '')::finance.loan_status;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    SELECT * INTO v_loan FROM finance.loans WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % not found.', v_id;
    END IF;

    -- Korrigierbare Guards
    IF v_irate IS NOT NULL AND v_irate < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Interest rate must not be negative, got ' || v_irate || '.');
    END IF;
    IF v_prate IS NOT NULL AND v_prate < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Principal rate must not be negative, got ' || v_prate || '.');
    END IF;
    -- numeric(6,4) kuerzte > 4 Nachkommastellen still bzw. warf ab 100 Overflow (Rundungs-Paket 2026-10-23)
    v_reason := COALESCE(finance.fn_rate_precision_reason(v_irate, 'Interest rate'),
                         finance.fn_rate_precision_reason(v_prate, 'Principal rate'));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    IF v_annuity IS NOT NULL AND v_annuity <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Monthly annuity must be positive when given, got ' || v_annuity || '.');
    END IF;

    -- Korrigierbar: aktiver Kredit braucht eine Annuitaet (sonst greift finance_loans_active_needs_annuity).
    v_eff_status  := COALESCE(v_status, v_loan.status);
    v_eff_annuity := COALESCE(v_annuity, v_loan.monthly_annuity);
    IF v_eff_status = 'active' AND v_eff_annuity IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'An active loan needs a monthly annuity. Provide monthly_annuity or set the loan to paused.');
    END IF;
    -- Korrigierbar (Live-Befund 2026-10-24): neue Rate bzw. neuer Zins -> die wirksame Rate muss den Monatszins der
    -- Restschuld je Raten-Periode decken (dieselbe Formel + derselbe Perioden-Faktor wie jede Buchung,
    -- fn_get_loan_payment_split: fn_loan_monthly_interest x fn_loan_period_months).
    IF (v_annuity IS NOT NULL OR v_irate IS NOT NULL) AND v_eff_annuity IS NOT NULL THEN
        SELECT finance.fn_loan_monthly_interest(-balance, COALESCE(v_irate, v_loan.interest_rate),
                   finance.fn_loan_period_months(v_loan.recurring_payment_id)) INTO v_interest
        FROM finance.account_balances WHERE account_id = v_loan.loan_account_id;
        IF v_eff_annuity < v_interest THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The monthly rate ' || v_eff_annuity || ' does not cover the monthly interest ' || v_interest
                       || ' on the remaining debt - check the rate and the interest rate.',
                'interest', v_interest, 'payment', v_eff_annuity);
        END IF;
    END IF;

    UPDATE finance.loans SET
        name                      = COALESCE(NULLIF(p->>'name', ''), name),
        lender                    = COALESCE(NULLIF(p->>'lender', ''), lender),
        borrower_person_id        = COALESCE(NULLIF(p->>'borrower_person_id', ''), borrower_person_id),  -- WS-4: typisierter Kreditnehmer (Slug); leer=unveraendert
        interest_rate             = COALESCE(v_irate, interest_rate),
        principal_rate            = COALESCE(v_prate, principal_rate),
        interest_rate_fixed_until = COALESCE(NULLIF(p->>'interest_rate_fixed_until', '')::date, interest_rate_fixed_until),
        monthly_annuity           = COALESCE(v_annuity, monthly_annuity),
        schedule_day_of_month     = COALESCE(v_dom, schedule_day_of_month),
        status                    = COALESCE(v_status, status),
        notes                     = COALESCE(NULLIF(p->>'notes', ''), notes)
    WHERE id = v_id;

    -- Recurring-Sync (verknuepfte Kreditrate) + Status-Kaskade.
    IF v_loan.recurring_payment_id IS NOT NULL THEN
        IF v_annuity IS NOT NULL THEN
            UPDATE finance.recurring_payments SET amount = -v_annuity WHERE id = v_loan.recurring_payment_id;
        END IF;
        IF v_dom IS NOT NULL THEN
            UPDATE finance.recurring_payments SET schedule_day_of_month = v_dom WHERE id = v_loan.recurring_payment_id;
        END IF;
        IF v_status IS NOT NULL THEN
            UPDATE finance.recurring_payments
            SET status = CASE WHEN v_status = 'active' THEN 'active' ELSE 'paused' END::finance.payment_status
            WHERE id = v_loan.recurring_payment_id;
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'loan_id', v_id, 'recurring_payment_id', v_loan.recurring_payment_id);
END;
$$;
