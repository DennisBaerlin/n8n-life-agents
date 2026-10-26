-- ============================================================
-- fn_book_loan_payment (ATOMIC WRITE)
--   Bucht eine Kreditrate in EINER Transaktion:
--   (1) Abbuchung vom Girokonto (-payment_amount, category='loan_payment'),
--   (2) Tilgungsanteil auf das Kreditkonto (+principal, category='principal').
--   Zinsanteil = payment_amount - principal (implizit, nicht als eigene Zeile gespeichert).
--   Zins/Tilgung + Faelligkeits-Zuordnung kommen aus fn_get_loan_payment_split (EINE Formel fuer HITL-Vorschau
--   und Buchung, Audit F1c). Saldo-Zeile wird VORHER gesperrt (FOR UPDATE OF b, Cron ∥ Chat -> kein TOCTOU).
--   FAELLIGKEIT (Audit F1b): eine regulaere Rate stempelt recurring_payment_id auf das Giro-Bein und bucht auf das
--   due_date des naechstgelegenen offenen Vorkommens der Kredit-rp (explizites due_date = Scheduler-Pfad aus
--   fn_book_recurring_occurrence) -> die Erinnerung bietet die bezahlte Rate nicht erneut an (vorher Doppelbuchung).
--   REINE ZINSRATE (Audit Paket 2): Tilgung 0 -> nur das Giro-Bein (kein 0-EUR-Tilgungsbein, das den CHECK
--   principal => amount > 0 mit Owner-Alarm verletzte); principal_tx_id = null.
--   ABBEZAHLT (Audit Paket 2): bringt die Rate die Restschuld auf 0 -> fn_mark_loan_paid_off (Kredit paid_off,
--   Raten-rp endet am Tag nach der Rate, Vorzustand in settled_from -> fn_void_transaction stellt ihn her).
--   Eingabe jsonb: loan_id, loan_account_id, debit_account_id, payment_amount (optional, WP2: leer = die faellige Rate
--   laut fn_get_loan_payment_split), payment_date, principal_amount (optional; leer = berechnen), due_date (optional; Scheduler),
--   recurring_payment_id (optional; Scheduler: das Ketten-Glied, dessen Vorkommen gebucht wird),
--   transaction_date (optional, Monats-Check WP-A: Ist-Datum laut Kontoauszug; ohne -> Buchung auf das zugeordnete
--   due_date wie bisher). Identitaet des Vorkommens = recurring_due_date = zugeordnetes due_date.
--   ABGLEICH-SPERRE: Buchungsdatum <= letzter Abgleich des Belastungskontos -> {ok:false, code:'reconciled'}.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, loan_payment_tx_id, principal_tx_id, payment_amount (gebuchte Rate,
--   bei leerer Eingabe DB-abgeleitet), interest_portion, principal_amount, remaining_debt, matched_due_date, loan_status} (Post-State: neue Restschuld
--   NACH der Tilgung + Kredit-Status, in derselben Transaktion gelesen; matched_due_date = gestempeltes Vorkommen
--   oder null).
--   Korrigierbarer Fall (Ueberzahlung/Unterzahlung/nicht-positive Rate/Vorkommen schon gebucht) ->
--   {ok:false, reason, ...betraege} OHNE Write (kein RAISE -> kein Owner-Alert). Bei Ueberzahlung wird die exakte
--   Abloesesumme (payoff_amount = Restschuld + Zins) mitgegeben, damit der Agent sie anbieten kann.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_loan_payment(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_loan_id      INT     := (p->>'loan_id')::int;
    v_loan_acc     INT     := (p->>'loan_account_id')::int;
    v_debit_acc    INT     := (p->>'debit_account_id')::int;
    v_payment      NUMERIC := NULLIF(p->>'payment_amount', '')::numeric;   -- leer = die faellige Rate (fn_get_loan_payment_split)
    v_split        JSONB;
    v_interest     NUMERIC;
    v_principal    NUMERIC;
    v_date         DATE;
    v_rp_id        INT;
    v_pay_tx       INT;
    v_principal_tx INT;
    v_rest_after   NUMERIC;
    v_reason       TEXT;
    v_group        UUID := gen_random_uuid();   -- Multi-Leg: Giro-Bein + principal-Bein teilen eine group_id
    v_dates        JSONB;
BEGIN
    -- relative Datumsangaben ("yesterday", "-3 days") -> ISO, bevor fn_get_loan_payment_split sie liest;
    -- nicht aufloesbar -> {ok:false, code:'invalid_date'}. effective traegt sie fest in den Write nach der Karte.
    v_dates := core.fn_resolve_input_dates(p, ARRAY['payment_date', 'due_date', 'transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    -- Korrigierbar: eine genannte Rate muss positiv sein (vor dem Lock; die Split-fn prueft es ebenfalls).
    IF v_payment <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Payment amount must be a positive number, got ' || COALESCE(v_payment::text, 'null') || '.');
    END IF;

    -- Korrigierbar (Audit Paket 2, Kontotyp): die Rate zahlt ein Geld-Konto, nie ein Depot oder ein Kreditkonto
    -- (sonst Backstop-RAISE mit Owner-Alarm bzw. still erhoehte Restschuld eines anderen Kredits).
    v_reason := finance.fn_bookable_account_reason(v_debit_acc);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- FOR UPDATE OF b: Saldo-Zeile sperren (Cron ∥ Chat), DANN Zins/Tilgung aus der einen Formel lesen.
    PERFORM 1
    FROM finance.account_balances b
    JOIN finance.loans l ON l.loan_account_id = b.account_id AND l.id = v_loan_id
    WHERE b.account_id = v_loan_acc
    FOR UPDATE OF b;

    v_split := finance.fn_get_loan_payment_split(p);
    IF (v_split->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_split;
    END IF;
    v_payment   := (v_split->>'payment_amount')::numeric;
    v_interest  := (v_split->>'interest_portion')::numeric;
    v_principal := (v_split->>'principal_amount')::numeric;
    v_date      := COALESCE(NULLIF(p->>'transaction_date', '')::date, (v_split->>'booking_date')::date);
    v_rp_id     := NULLIF(v_split->>'recurring_payment_id', '')::int;

    -- Abgleich-Sperre (Monats-Check WP-A): der Saldo-Abgleich des Belastungskontos enthaelt die Rate schon.
    v_reason := finance.fn_reconciled_reason(v_debit_acc, v_date);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'reconciled', 'reason', v_reason);
    END IF;

    -- 1. Abbuchung vom Girokonto (ganze Rate: Zins + Tilgung); regulaere Rate traegt die Faelligkeit (rp-Stempel +
    --    recurring_due_date). Race-Backstop: partieller UNIQUE (recurring_payment_id, recurring_due_date, account_id).
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, loan_id, recurring_payment_id, recurring_due_date,
         description, group_id)
    VALUES (
        v_debit_acc,
        -v_payment,
        v_date,
        'loan_payment',
        v_loan_id,
        v_rp_id,
        CASE WHEN v_rp_id IS NOT NULL THEN (v_split->>'matched_due_date')::date END,
        'Kreditrate ' || v_payment || ' EUR (Tilgung ' || v_principal || ' + Zins ' || v_interest || ')',
        v_group
    )
    ON CONFLICT (recurring_payment_id, recurring_due_date, account_id) WHERE recurring_payment_id IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_pay_tx;

    IF v_pay_tx IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'The loan installment due on ' || v_date || ' is already booked.');
    END IF;

    -- 2. Tilgungsanteil auf das Kreditkonto (reduziert die Restschuld); reine Zinsrate -> kein Tilgungsbein.
    IF v_principal > 0 THEN
        INSERT INTO finance.transactions
            (account_id, amount, transaction_date, category, loan_id, description, group_id)
        VALUES (
            v_loan_acc,
            v_principal,
            v_date,
            'principal',
            v_loan_id,
            'Tilgung Kreditrate ' || v_date,
            v_group
        )
        RETURNING id INTO v_principal_tx;
    END IF;

    -- Post-State (Trigger hat gefeuert): neue Restschuld = negativer Loan-Konto-Saldo.
    SELECT GREATEST(-balance, 0) INTO v_rest_after
    FROM finance.account_balances WHERE account_id = v_loan_acc;

    -- 3. Restschuld 0 -> abbezahlt; die Raten-rp endet am Tag NACH der Rate (die gebuchte Rate bleibt gueltig).
    IF v_rest_after = 0 AND v_principal > 0 THEN
        PERFORM finance.fn_mark_loan_paid_off(v_loan_id, v_date + 1);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'loan_payment_tx_id', v_pay_tx,
        'principal_tx_id',    v_principal_tx,
        'payment_amount',     v_payment,
        'interest_portion',   v_interest,
        'principal_amount',   v_principal,
        'remaining_debt',     v_rest_after,
        'matched_due_date',   v_split->'matched_due_date',
        'loan_status',        (SELECT status::text FROM finance.loans WHERE id = v_loan_id),
        'effective',          v_dates->'resolved'
    );
END;
$$;
