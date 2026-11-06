-- ============================================================
-- fn_get_loan_payment_split (READ) -- die EINE Zins/Tilgungs-Formel einer Kreditrate (Audit F1c/F7)
--   Gerufen von der HITL-Vorschau in tool_book_loan_payment (read-only, Tool-Cred finance_rw; auch unter
--   finance_ro lesbar), von fn_book_loan_payment (Buchung) und von fn_recurring_occurrence_amount (Erinnerung)
--   -> Karte, Erinnerung und Buchung zeigen garantiert dieselben Zahlen. Zins = fn_loan_monthly_interest (Restschuld
--   * Zinssatz / 1200, die eine Formel auch der Cashflow-Klassifikation) * Monate je Raten-Periode (Audit Paket 2: eine Quartalsrate traegt drei Monatszinsen, vorher nur einen;
--   Periode aus Kadenz der Kredit-rp ueber fn_loan_period_months, ohne rp = 1 Monat);
--   Tilgung = Rate - Zins; mit explizitem principal_amount: Zins = Rate - Tilgung.
--   FAELLIGKEITS-ZUORDNUNG (Audit F1b): eine regulaere Rate (Betrag = geplante Rate eines Glieds der Raten-Kette, oder
--   die letzte Rate, die den Kredit genau abloest)
--   schliesst das NAECHSTGELEGENE offene Vorkommen im Fenster payment_date - 1 Monat < due_date <= payment_date
--   + 14 Tage (auch ein paar Tage zu frueh bezahlt; gebucht wird auf dessen due_date, wie
--   fn_book_savings_plan_execution). Explizites due_date (Scheduler-Pfad) gewinnt; gestempelt wird die mitgegebene
--   recurring_payment_id (das Glied, dessen Vorkommen gebucht wird; Default = Kopf), "schon gebucht" gilt ueber
--   die ganze Vorgaenger-Kette (Audit Paket 2 A0) und unabhaengig vom Belastungskonto. Aeltere offene Raten werden
--   nie still rueckdatiert; abweichende Betraege (Sondertilgung) bleiben ungestempelt.
--   OHNE BETRAG (WP2 "Finanzen schlank", weniger Rueckfragen): payment_amount leer = die faellige Rate -- der Betrag
--   des naechstgelegenen offenen Vorkommens der Raten-Kette im selben Fenster (bzw. am expliziten due_date), bei der
--   letzten Rate der Abloesebetrag (Restschuld + Zins), wenn die volle Rate ueberzahlen wuerde. Ohne Raten-Kette oder
--   ohne offenes Vorkommen -> {ok:false} (Betrag nennen).
--   Eingabe jsonb: loan_id, payment_amount (opt), payment_date (ISO oder relativ, leer = heute), principal_amount (opt), due_date (opt),
--   recurring_payment_id (opt, Scheduler-Stempel).
--   RUECKGABE: {ok:true, payment_amount (gegeben oder abgeleitet), remaining_debt (vor der Rate), interest_portion,
--   principal_amount, matched_due_date, booking_date, recurring_payment_id (nur bei Zuordnung)} | korrigierbar
--   {ok:false, reason, ...betraege} (Rate <= 0, keine faellige Rate, Tilgung < 0 oder > Rate, Unterzahlung,
--   Ueberzahlung inkl. payoff_amount, schon gebucht). RAISE nur bei not-found.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_loan_payment_split(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_loan_id    INT     := (p->>'loan_id')::int;
    v_payment    NUMERIC := NULLIF(p->>'payment_amount', '')::numeric;
    v_date       DATE;
    v_principal  NUMERIC := NULLIF(p->>'principal_amount', '')::numeric;
    v_due        DATE;
    v_stamp_rp   INT     := NULLIF(p->>'recurring_payment_id', '')::int;
    v_loan       finance.loans%ROWTYPE;
    v_months     NUMERIC := 1;
    v_restschuld NUMERIC;
    v_interest   NUMERIC;
    v_def_rp     INT;
    v_dates      JSONB;
BEGIN
    -- relative Datumsangaben ("yesterday", "-3 days") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['payment_date', 'due_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'payment_date', '')::date, core.fn_today());
    v_due  := NULLIF(p->>'due_date', '')::date;
    SELECT * INTO v_loan FROM finance.loans WHERE id = v_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % not found.', v_loan_id;
    END IF;

    -- Ohne Betrag: die faellige Rate (eigener Zweig; kein Aufruf von fn_recurring_occurrence_amount, die ihrerseits
    -- diese fn ruft). Zins mit dem Perioden-Faktor des gefundenen Glieds.
    IF v_payment IS NULL THEN
        IF v_loan.recurring_payment_id IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'This loan has no regular rate - ask the user for the payment amount.');
        END IF;
        SELECT o.recurring_payment_id, abs(r.amount) INTO v_def_rp, v_payment
        FROM finance.fn_recurring_due_open(COALESCE(v_due, (v_date - interval '1 month')::date),
                                           COALESCE(v_due, v_date + 14)) o
        JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id
        WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_loan.recurring_payment_id))
          AND (v_due IS NULL OR o.due_date = v_due)
          AND (v_due IS NOT NULL OR o.due_date > (v_date - interval '1 month')::date)
        ORDER BY abs(o.due_date - v_date), o.due_date
        LIMIT 1;
        IF v_payment IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'No open installment of this loan is due around ' || v_date
                       || ' - ask the user for the payment amount (or whether it is already booked).');
        END IF;
        SELECT GREATEST(-balance, 0) INTO v_restschuld
        FROM finance.account_balances WHERE account_id = v_loan.loan_account_id;
        v_interest := finance.fn_loan_monthly_interest(v_restschuld, v_loan.interest_rate,
                                                       finance.fn_loan_period_months(v_def_rp));
        IF v_payment - v_interest > v_restschuld THEN
            v_payment := ROUND(v_restschuld + v_interest, 2);   -- letzte Rate = Abloesebetrag
        END IF;
        v_stamp_rp := COALESCE(v_stamp_rp, v_def_rp);
    END IF;

    IF v_payment <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Payment amount must be a positive number, got ' || v_payment || '.');
    END IF;
    -- Korrigierbar (Audit Paket 2): Tilgung negativ oder groesser als die Rate -> Zins waere negativ.
    IF v_principal IS NOT NULL AND (v_principal < 0 OR v_principal > v_payment) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The principal portion ' || v_principal || ' must be between 0 and the payment amount '
                   || v_payment || ' (the rest is interest).',
            'principal', v_principal, 'payment', v_payment);
    END IF;

    -- Monate je Raten-Periode aus der Kadenz des Glieds, dessen Vorkommen gebucht wird (Scheduler-Stempel), sonst
    -- des Kopfs der Kette (Code-Review Paket 3: ein in die Zukunft datierter Kadenzwechsel darf die laufende alte
    -- Monatsrate nicht mit drei Monatszinsen belasten).
    -- (die eine Adresse: fn_loan_period_months; ohne rp = 1 Monat)
    IF v_loan.recurring_payment_id IS NOT NULL THEN
        v_months := finance.fn_loan_period_months(COALESCE(v_stamp_rp, v_loan.recurring_payment_id));
    END IF;

    SELECT GREATEST(-balance, 0) INTO v_restschuld
    FROM finance.account_balances WHERE account_id = v_loan.loan_account_id;

    IF v_principal IS NULL THEN
        -- Audit Paket 3: die EINE Zinsformel (fn_loan_monthly_interest) mit dem Perioden-Faktor der Rate.
        v_interest  := finance.fn_loan_monthly_interest(v_restschuld, v_loan.interest_rate, v_months);
        v_principal := v_payment - v_interest;
    ELSE
        v_interest := ROUND(v_payment - v_principal, 2);
    END IF;

    -- Unterzahlung: Rate deckt die Zinsen nicht -> korrigierbar.
    IF v_principal < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Payment of ' || v_payment || ' does not cover the interest portion ('
                   || v_interest || '). Ask the user for a higher payment.',
            'interest', v_interest,
            'payment', v_payment);
    END IF;

    -- Ueberzahlung: Tilgung uebersteigt die Restschuld -> korrigierbar (Abloese anbieten).
    IF v_restschuld IS NOT NULL AND v_principal > v_restschuld THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Payment would overpay the loan: the principal portion ' || v_principal
                   || ' exceeds the remaining debt ' || v_restschuld || '. The payoff amount is '
                   || ROUND(v_restschuld + v_interest, 2) || ' (remaining debt + interest ' || v_interest
                   || '). Ask the user whether to book the payoff instead.',
            'remaining_debt', v_restschuld,
            'interest', v_interest,
            'payoff_amount', ROUND(v_restschuld + v_interest, 2));
    END IF;

    -- Faelligkeits-Zuordnung (nur fuer Kredite mit Raten-rp), ueber die ganze Vorgaenger-Kette.
    IF v_loan.recurring_payment_id IS NOT NULL AND v_due IS NOT NULL THEN
        v_stamp_rp := COALESCE(v_stamp_rp, v_loan.recurring_payment_id);
        -- Explizite Faelligkeit (Scheduler): schon gebucht? Unabhaengig vom Belastungskonto und vom Glied der Kette
        -- (der Unique-Index greift nur bei gleichem account_id + rp) -> laeuft in fn_book_loan_payment NACH dem Lock.
        IF EXISTS (SELECT 1 FROM finance.transactions
                   WHERE recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_loan.recurring_payment_id))
                     AND recurring_due_date = v_due) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
                'reason', 'The loan installment due on ' || v_due || ' is already booked.');
        END IF;
    ELSIF v_loan.recurring_payment_id IS NOT NULL THEN
        -- naechstgelegenes offenes Vorkommen eines Ketten-Glieds mit genau dieser Rate:
        -- bis 1 Monat zurueck ODER bis 14 Tage voraus (frueh bezahlt)
        SELECT o.due_date, o.recurring_payment_id INTO v_due, v_stamp_rp
        FROM finance.fn_recurring_due_open(v_date + 14) o
        JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id
        WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_loan.recurring_payment_id))
          AND (ROUND(v_payment, 2) = ROUND(abs(r.amount), 2)
               -- letzte, kleinere Rate: zahlt die Zahlung den Kredit genau ab (Tilgung = Restschuld), ist sie die
               -- faellige Rate (dieselbe Regel wie fn_recurring_occurrence_amount; sonst bliebe das Vorkommen offen)
               OR (v_restschuld IS NOT NULL AND v_restschuld > 0 AND v_principal = v_restschuld))
          AND o.due_date > (v_date - interval '1 month')::date
        ORDER BY abs(o.due_date - v_date), o.due_date
        LIMIT 1;
    END IF;

    RETURN jsonb_build_object('ok', true,
        'payment_amount',       v_payment,
        'remaining_debt',       v_restschuld,
        'interest_portion',     v_interest,
        'principal_amount',     v_principal,
        'matched_due_date',     v_due,
        'booking_date',         COALESCE(v_due, v_date),
        'recurring_payment_id', CASE WHEN v_due IS NOT NULL THEN v_stamp_rp END);
END;
$$;
