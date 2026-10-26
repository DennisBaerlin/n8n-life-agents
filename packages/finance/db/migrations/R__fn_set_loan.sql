-- ============================================================
-- fn_set_loan (ATOMIC WRITE)
--   Aendert Konditionen/Status eines bestehenden Kredits. Partielles Update (leer = unveraendert; Leeren geht nicht).
--   Zins/Tilgung je Rate liefert finance.loan_overview LIVE aus der Restschuld.
--   RATE / ABBUCHUNGSTAG (WP2 "Finanzen schlank"): stehen nur an der Raten-Kette. Eine Aenderung laeuft ueber
--   fn_change_owned_recurring: Korrektur direkt nach der Anlage in place, sonst ein neues Glied ab effective_from
--   (Default: naechster noch nicht erledigter Termin) -- die alte Rate bleibt Historie (vorher in place ueberschrieben;
--   ein neuer Tag verschob sogar das Raster gebuchter Termine). Kredit OHNE Raten-Kette + Rate -> neue Kette ab
--   effective_from (Pflicht: Termin der ersten Rate); ohne genannten Status wird der Kredit dabei aktiv.
--   URSPRUNGSWERTE: original_amount / disbursement_date nur bei einem Kredit, der zum Stichtag eroeffnet wurde
--   (Kreditkonto mit opening_balance_date, ohne eigenes Auszahlungskonto) -- dort haengt keine Buchung daran. Bei einem
--   frischen Kredit stecken sie in der Eroeffnungs-/Auszahlungsbuchung -> {ok:false}. Guards: Datum nicht in der Zukunft
--   und nicht nach dem Eroeffnungs-Stichtag, Betrag nicht unter der Eroeffnungs-Restschuld.
--   LAUFZEIT: term_end_date (Laufzeitende), interest_rate_fixed_until; Spiegel von CHECK finance_loans_term_end_chk.
--   NAMEN: eine Umbenennung fuehrt 'Kreditrate <Name>' (Raten-Kette, fn_rename_owned_recurring) und das Kreditkonto
--   'Kredit <Name>' mit.
--   STATUS-KASKADE: paused/paid_off/refinanced -> alle noch laufenden Glieder der Kette 'paused'; active -> 'active'.
--   NICHT abgebildet: der mehrschrittige Umschuldungs-Flow (neues Konto + Settlement-Buchung + neuer Kredit).
--   Eingabe jsonb: loan_id (im n8n aufgeloest), name, lender, borrower_person_id (Slug; leer=unveraendert),
--   interest_rate, interest_rate_fixed_until, term_end_date, monthly_annuity, schedule_day_of_month, effective_from,
--   original_amount, disbursement_date, status, notes.
--   RUECKGABE: {ok:true, loan_id, recurring_payment_id (Kopf), split, previous_id (nur bei Split), effective_from (nur
--   bei Raten-/Tagesaenderung), balance_at_fixed_until, balance_at_term_end (voraussichtliche Restschuld, loan_overview)}.
--   Korrigierbar (neg. Zins, Rate<=0, aktiv ohne Rate, Rate ohne ersten Termin, unbekannter status, wirksame Rate unter
--   dem Monatszins der Restschuld -> {interest, payment}, Ursprungswerte bei frischem Kredit / Datum in der Zukunft /
--   Betrag unter der Eroeffnungs-Restschuld, Laufzeit-Widerspruch, Split-Guards, kein Wert weicht vom Bestand ab ->
--   {no_change:true}) -> {ok:false} OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_loan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id          INT      := (p->>'loan_id')::int;
    v_irate       NUMERIC  := NULLIF(p->>'interest_rate', '')::numeric;
    v_annuity     NUMERIC  := NULLIF(p->>'monthly_annuity', '')::numeric;
    v_dom         SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_eff_from    DATE     := NULLIF(p->>'effective_from', '')::date;
    v_amount      NUMERIC  := NULLIF(p->>'original_amount', '')::numeric;
    v_disb        DATE     := NULLIF(p->>'disbursement_date', '')::date;
    v_status      finance.loan_status;   -- Cast erst nach dem Enum-Guard (Import-Haertung)
    v_reason      TEXT     := finance.fn_enum_reason('finance.loan_status'::regtype, p->>'status', 'status');
    v_today       DATE     := core.fn_today();
    v_loan        finance.loans%ROWTYPE;
    v_acc         finance.accounts%ROWTYPE;
    v_cur_amount  NUMERIC;
    v_eff_status  finance.loan_status;
    v_eff_annuity NUMERIC;
    v_interest    NUMERIC;
    v_open_debt   NUMERIC;
    v_fixed       DATE;
    v_term_end    DATE;
    v_name        TEXT;
    v_rp          INT;
    v_chg         JSONB    := '{}'::jsonb;
    v_ov          RECORD;
BEGIN
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_status := NULLIF(p->>'status', '')::finance.loan_status;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    SELECT * INTO v_loan FROM finance.loans WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % not found.', v_id;
    END IF;
    SELECT * INTO v_acc FROM finance.accounts WHERE id = v_loan.loan_account_id;
    v_rp := v_loan.recurring_payment_id;
    SELECT abs(amount) INTO v_cur_amount FROM finance.recurring_payments
     WHERE id = finance.fn_recurring_current(v_rp, v_today);

    -- Korrigierbare Guards
    IF v_irate IS NOT NULL AND v_irate < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Interest rate must not be negative, got ' || v_irate || '.');
    END IF;
    -- numeric(6,4) kuerzte > 4 Nachkommastellen still bzw. warf ab 100 Overflow (Rundungs-Paket 2026-10-23)
    v_reason := finance.fn_rate_precision_reason(v_irate, 'Interest rate');
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    IF v_annuity IS NOT NULL AND v_annuity <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Monthly annuity must be positive when given, got ' || v_annuity || '.');
    END IF;
    IF v_rp IS NULL AND v_annuity IS NULL AND v_dom IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This loan has no rate yet - give the monthly rate and the date of its first debit (effective_from) together with the debit day.');
    END IF;
    IF v_rp IS NULL AND v_annuity IS NOT NULL AND v_eff_from IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This loan has no rate yet - give the date of the first debit of the new rate (effective_from).');
    END IF;

    -- Ursprungswerte: nur bei einem zum Stichtag eroeffneten Kredit ohne eigenes Auszahlungskonto (keine Buchung haengt daran)
    IF v_amount IS NOT NULL OR v_disb IS NOT NULL THEN
        IF v_acc.opening_balance_date IS NULL OR v_loan.disbursement_account_id IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The loan amount and payout date of this loan are part of its payout booking and cannot be changed here. '
                       || 'If they are wrong, delete the loan and record it again.');
        END IF;
        IF v_amount IS NOT NULL AND v_amount <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Loan amount (original_amount) must be a positive number, got ' || v_amount || '.');
        END IF;
        IF v_disb > v_today OR v_disb > v_acc.opening_balance_date THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The payout date ' || v_disb || ' must not be after ' || LEAST(v_today, v_acc.opening_balance_date)
                       || ' (the loan was recorded with its remaining debt as of that day).',
                'opening_balance_date', v_acc.opening_balance_date);
        END IF;
        SELECT -t.amount INTO v_open_debt FROM finance.transactions t
         WHERE t.loan_id = v_id AND t.account_id = v_loan.loan_account_id AND t.category = 'disbursement'
         ORDER BY t.id LIMIT 1;
        IF v_amount IS NOT NULL AND v_amount < v_open_debt THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The loan amount ' || v_amount || ' is below the remaining debt ' || v_open_debt
                       || ' the loan was recorded with - check the amount.',
                'opening_remaining_debt', v_open_debt);
        END IF;
    END IF;

    -- Laufzeit (Spiegel CHECK finance_loans_term_end_chk)
    v_fixed    := COALESCE(NULLIF(p->>'interest_rate_fixed_until', '')::date, v_loan.interest_rate_fixed_until);
    v_term_end := COALESCE(NULLIF(p->>'term_end_date', '')::date, v_loan.term_end_date);
    IF v_term_end IS NOT NULL AND (v_term_end < v_fixed OR v_term_end < COALESCE(v_disb, v_loan.disbursement_date)) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The end of the term (' || v_term_end || ') must not be before the end of the fixed-interest period '
                   || 'or the payout date.');
    END IF;

    -- Korrigierbar: aktiver Kredit braucht eine Rate (CHECK finance_loans_active_needs_annuity: aktiv <=> Raten-Kette).
    v_eff_annuity := COALESCE(v_annuity, v_cur_amount);
    v_eff_status  := COALESCE(v_status,
                              CASE WHEN v_rp IS NULL AND v_annuity IS NOT NULL THEN 'active'::finance.loan_status END,
                              v_loan.status);
    IF v_eff_status = 'active' AND v_eff_annuity IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'An active loan needs a monthly annuity. Provide monthly_annuity (with effective_from) or set the loan to paused.');
    END IF;
    -- Korrigierbar (Live-Befund 2026-10-24): neue Rate bzw. neuer Zins -> die wirksame Rate muss den Monatszins der
    -- Restschuld je Raten-Periode decken (dieselbe Formel + derselbe Perioden-Faktor wie jede Buchung).
    IF (v_annuity IS NOT NULL OR v_irate IS NOT NULL) AND v_eff_annuity IS NOT NULL THEN
        SELECT finance.fn_loan_monthly_interest(-balance, COALESCE(v_irate, v_loan.interest_rate),
                   finance.fn_loan_period_months(v_rp)) INTO v_interest
        FROM finance.account_balances WHERE account_id = v_loan.loan_account_id;
        IF v_eff_annuity < v_interest THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The monthly rate ' || v_eff_annuity || ' does not cover the monthly interest ' || v_interest
                       || ' on the remaining debt - check the rate and the interest rate.',
                'interest', v_interest, 'payment', v_eff_annuity);
        END IF;
    END IF;

    -- Korrigierbar (Live-Befund 2026-10-26): nichts weicht vom Bestand ab -> {ok:false, no_change} OHNE Write. Der
    -- Probelauf meldet das vor der Karte; ein wiederholter Aufruf mit denselben Werten zeigt keine zweite Karte.
    IF NOT (COALESCE(NULLIF(p->>'name', ''), v_loan.name) IS DISTINCT FROM v_loan.name
         OR COALESCE(NULLIF(p->>'lender', ''), v_loan.lender) IS DISTINCT FROM v_loan.lender
         OR COALESCE(NULLIF(p->>'borrower_person_id', ''), v_loan.borrower_person_id) IS DISTINCT FROM v_loan.borrower_person_id
         OR COALESCE(v_irate, v_loan.interest_rate) IS DISTINCT FROM v_loan.interest_rate
         OR v_fixed IS DISTINCT FROM v_loan.interest_rate_fixed_until
         OR v_term_end IS DISTINCT FROM v_loan.term_end_date
         OR COALESCE(v_amount, v_loan.original_amount) IS DISTINCT FROM v_loan.original_amount
         OR COALESCE(v_disb, v_loan.disbursement_date) IS DISTINCT FROM v_loan.disbursement_date
         OR v_eff_status IS DISTINCT FROM v_loan.status
         OR COALESCE(NULLIF(p->>'notes', ''), v_loan.notes) IS DISTINCT FROM v_loan.notes
         OR (v_annuity IS NOT NULL AND v_annuity IS DISTINCT FROM v_cur_amount)
         OR (v_dom IS NOT NULL AND v_dom IS DISTINCT FROM (SELECT schedule_day_of_month FROM finance.recurring_payments
                                                            WHERE id = finance.fn_recurring_current(v_rp, v_today)))) THEN
        RETURN jsonb_build_object('ok', false, 'no_change', true,
            'reason', 'Nothing to change: the loan already has exactly these values - the earlier change is saved. '
                   || 'Do not call tool_set_loan again for it.');
    END IF;

    -- Rate / Abbuchungstag: neue Kette bzw. Aenderung ueber die Kette (Historie)
    IF v_rp IS NULL AND v_annuity IS NOT NULL THEN
        v_rp := finance.fn_add_recurring_payment(
            v_loan.debit_account_id, -v_annuity, left('Kreditrate ' || COALESCE(NULLIF(p->>'name', ''), v_loan.name), 100),
            1::smallint, 'month'::finance.schedule_unit, v_dom, v_eff_from,
            GREATEST(finance.fn_recurring_valid_from(v_loan.debit_account_id, v_eff_from),
                     finance.fn_recurring_valid_from(v_loan.loan_account_id, v_eff_from)),
            NULL, NULL, NULL);
        v_chg := jsonb_build_object('split', false, 'effective_from', v_eff_from);
    ELSIF v_rp IS NOT NULL AND ((v_annuity IS NOT NULL AND v_annuity IS DISTINCT FROM v_cur_amount) OR v_dom IS NOT NULL) THEN
        v_chg := finance.fn_change_owned_recurring(v_rp, v_eff_from, -v_annuity, NULL, NULL, v_dom);
        IF (v_chg->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_chg;
        END IF;
        v_rp := (v_chg->>'recurring_payment_id')::int;
    END IF;

    v_name := COALESCE(NULLIF(p->>'name', ''), v_loan.name);
    UPDATE finance.loans SET
        name                      = v_name,
        lender                    = COALESCE(NULLIF(p->>'lender', ''), lender),
        borrower_person_id        = COALESCE(NULLIF(p->>'borrower_person_id', ''), borrower_person_id),  -- WS-4: typisierter Kreditnehmer (Slug); leer=unveraendert
        interest_rate             = COALESCE(v_irate, interest_rate),
        interest_rate_fixed_until = v_fixed,
        term_end_date             = v_term_end,
        original_amount           = COALESCE(v_amount, original_amount),
        disbursement_date         = COALESCE(v_disb, disbursement_date),
        recurring_payment_id      = v_rp,
        status                    = v_eff_status,
        notes                     = COALESCE(NULLIF(p->>'notes', ''), notes)
    WHERE id = v_id;

    -- Namenskopien mitfuehren (Raten-Kette + Kreditkonto)
    PERFORM finance.fn_rename_owned_recurring(v_rp, 'Kreditrate', v_loan.name, v_name);
    IF v_name IS DISTINCT FROM v_loan.name THEN
        UPDATE finance.accounts SET name = left('Kredit ' || v_name, 100)
         WHERE id = v_loan.loan_account_id AND name = 'Kredit ' || v_loan.name;
    END IF;

    -- Status-Kaskade auf alle noch laufenden Glieder der Kette (auch eine eben angelegte Kette eines pausierten Kredits)
    IF v_rp IS NOT NULL AND (v_status IS NOT NULL OR v_loan.recurring_payment_id IS NULL) THEN
        UPDATE finance.recurring_payments
           SET status = CASE WHEN v_eff_status = 'active' THEN 'active' ELSE 'paused' END::finance.payment_status
         WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))
           AND (valid_to IS NULL OR valid_to > v_today);
    END IF;

    SELECT balance_at_fixed_until_projected, balance_at_term_end_projected INTO v_ov
      FROM finance.loan_overview WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'loan_id', v_id, 'recurring_payment_id', v_rp)
        || jsonb_strip_nulls(jsonb_build_object(
               'split', v_chg->'split', 'previous_id', v_chg->'previous_id', 'effective_from', v_chg->'effective_from'))
        || jsonb_build_object('balance_at_fixed_until', v_ov.balance_at_fixed_until_projected,
                              'balance_at_term_end', v_ov.balance_at_term_end_projected);
END;
$$;
