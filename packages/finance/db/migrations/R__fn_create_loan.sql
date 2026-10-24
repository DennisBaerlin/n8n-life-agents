-- ============================================================
-- fn_create_loan (ATOMIC WRITE)
--   Legt in EINER Transaktion an: (1) Loan-Konto, (2) Loan-Stammdaten, (3) optional
--   recurring_payment fuer die Monatsrate (nur wenn monthly_annuity gesetzt) + FK-Link,
--   (4) Restschuld-Eroeffnung auf dem Loan-Konto (-current_balance), (5) optionale
--   Auszahlungsbuchung (+original_amount) auf disbursement_account_id NUR wenn dieses gesetzt ist
--   (Kreditsumme floss auf ein eigenes Konto). NULL = an Dritte/Verkaeufer oder laufender
--   Kredit -> keine Auszahlungsbuchung. Eingabe als jsonb:
--     name, lender, borrower_person_id (Slug, NULL=Haushalt), original_amount, current_balance (aktuelle Restschuld;
--     Fallback original_amount -> frischer Kredit), disbursement_date, interest_rate,
--     principal_rate, interest_rate_fixed_until, monthly_annuity, schedule_day_of_month,
--     first_payment_date (echtes erstes/naechstes Ratendatum; PFLICHT, sobald monthly_annuity gesetzt ist),
--     disbursement_account_id (im n8n aufgeloest; NULL = keine Auszahlungsbuchung),
--     debit_account_id (Rate; im n8n aufgeloest), real_estate_id (optional)
--   Die Raten-recurring_payment gilt fruehestens ab dem Eroeffnungssaldo-Stichtag des Abbuchungskontos
--   (fn_recurring_valid_from): fruehere Raten stecken schon im genannten Kontostand; first_payment_date bleibt Anker.
--   Kredit-Betraege sind EUR nach Modell (das Kredit-Konto traegt die Default-Waehrung) -> Abbuchungs- und
--   Auszahlungskonto in Fremdwaehrung werden abgelehnt.
--   RUECKGABE: {ok:true, loan_id, loan_account_id, debit_account_id, recurring_payment_id} | {ok:false, reason}
--   OHNE Write: Buchungstag, Betrag <= 0, Rate <= 0, Rate ohne first_payment_date, current_balance <= 0 oder
--   > original_amount, Auszahlungskonto bei laufendem Kredit (current < original -> die Auszahlung liegt in
--   der Vergangenheit und steckt schon im Kontostand), Konto nicht EUR, Abbuchungs-/Auszahlungskonto nicht
--   buchbar (Depot/Kredit: Rate bliebe ewig offen bzw. die Auszahlung scheiterte am Kontotyp-Trigger).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_loan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_loan_acc INT;
    v_loan_id  INT;
    v_rp_id    INT;
    v_amount   NUMERIC  := (p->>'original_amount')::numeric;
    v_current  NUMERIC  := COALESCE(NULLIF(p->>'current_balance', '')::numeric, (p->>'original_amount')::numeric);
    v_disb     DATE     := (p->>'disbursement_date')::date;
    v_annuity  NUMERIC  := NULLIF(p->>'monthly_annuity', '')::numeric;
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_first    DATE     := NULLIF(p->>'first_payment_date', '')::date;
    v_debit    INT      := (p->>'debit_account_id')::int;
    v_disbursement_id INT := NULLIF(p->>'disbursement_account_id', '')::int;
    v_group     UUID    := gen_random_uuid();   -- Multi-Leg: Restschuld-Eroeffnung + Auszahlung teilen eine group_id
    v_reason    TEXT;
    v_sim       TEXT;
BEGIN
    -- WP-2b: fester Buchungstag muss 1-28 oder -1 (Monatsletzter) sein (29/30/31 overflowen kurze Monate).
    IF NOT finance.fn_valid_schedule_dom(v_dom) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Booking day ' || v_dom || ' is invalid - allowed are 1-28 or -1 (last day of the month); '
                   || 'for the 29th/30th/31st use -1 (last day of the month).');
    END IF;
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loan amount (original_amount) must be a positive number, got ' || COALESCE(v_amount::text, 'null') || '.');
    END IF;
    IF v_annuity IS NOT NULL AND v_annuity <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Monthly annuity must be a positive number when given, got ' || v_annuity || '.');
    END IF;
    IF v_annuity IS NOT NULL AND v_first IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The date of the first (for a running loan: the next) rate debit (first_payment_date) is required when a monthly rate is given.');
    END IF;
    IF v_current <= 0 OR v_current > v_amount THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The remaining debt (current_balance ' || v_current || ') must be greater than 0 and not above the original amount (' || v_amount || ').');
    END IF;
    IF v_disbursement_id IS NOT NULL AND v_current < v_amount THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'For a loan that is already being repaid, the payout happened in the past and is part of today''s account balance - leave the disbursement account empty.');
    END IF;
    IF EXISTS (SELECT 1 FROM finance.accounts WHERE id IN (v_debit, v_disbursement_id) AND currency <> 'EUR') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loan amounts are kept in EUR - the debit and payout accounts must be EUR accounts.');
    END IF;
    v_reason := COALESCE(finance.fn_bookable_account_reason(v_debit), finance.fn_bookable_account_reason(v_disbursement_id),
                         -- numeric(6,4) kuerzte > 4 Nachkommastellen still (Rundungs-Paket 2026-10-23)
                         finance.fn_rate_precision_reason(NULLIF(p->>'interest_rate', '')::numeric, 'Interest rate'),
                         finance.fn_rate_precision_reason(NULLIF(p->>'principal_rate', '')::numeric, 'Principal rate'),
                         -- GENERATED annuity_rate = Zins + Tilgung ist ebenfalls numeric(6,4): Summe < 100
                         finance.fn_rate_precision_reason(NULLIF(p->>'interest_rate', '')::numeric
                             + COALESCE(NULLIF(p->>'principal_rate', '')::numeric, 0), 'Interest + principal rate'));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- 1. Loan-Konto (negativer Saldo = Restschuld; balance-Zeile via Trigger)
    INSERT INTO finance.accounts (name, account_type, bank, status)
    VALUES ('Kredit ' || (p->>'name'), 'loan', NULLIF(p->>'lender', ''), 'active')
    RETURNING id INTO v_loan_acc;

    -- Karten-Hinweis (hohe Schwelle): laufender Kredit (aktiv oder pausiert) bei derselben Bank mit gleichem Auszahlungsbetrag
    SELECT l.name INTO v_sim FROM finance.loans l
     WHERE l.status IN ('active', 'paused') AND NULLIF(btrim(p->>'lender'), '') IS NOT NULL
       AND lower(btrim(l.lender)) = lower(btrim(p->>'lender'))
       AND l.original_amount = NULLIF(p->>'original_amount', '')::numeric
     ORDER BY l.id LIMIT 1;

    -- 2. Loan-Stammdaten (annuity_rate/monthly_interest/monthly_principal sind GENERATED)
    INSERT INTO finance.loans
        (name, lender, borrower_person_id, original_amount, disbursement_date,
         interest_rate, principal_rate, interest_rate_fixed_until,
         monthly_annuity, schedule_day_of_month, status,
         loan_account_id, debit_account_id, disbursement_account_id, real_estate_id)
    VALUES (p->>'name', NULLIF(p->>'lender', ''), NULLIF(p->>'borrower_person_id', ''), v_amount, v_disb,   -- WS-4: typisierter Kreditnehmer (Slug); NULL=Haushalt.
            (p->>'interest_rate')::numeric, NULLIF(p->>'principal_rate', '')::numeric,
            NULLIF(p->>'interest_rate_fixed_until', '')::date,
            v_annuity, v_dom,
            CASE WHEN v_annuity IS NOT NULL THEN 'active' ELSE 'paused' END::finance.loan_status,
            v_loan_acc, v_debit, v_disbursement_id, NULLIF(p->>'real_estate_id', '')::int)
    RETURNING id INTO v_loan_id;

    -- 3. Recurring-Payment fuer die Monatsrate (nur bei vorhandener Annuitaet) + FK-Link
    IF v_annuity IS NOT NULL THEN
        -- recurring_payment via gemeinsamen Helper (Teil 0: eine Quelle fuer den Insert).
        v_rp_id := finance.fn_add_recurring_payment(
            v_debit, -v_annuity, 'Kreditrate ' || (p->>'name'),
            1::smallint, 'month'::finance.schedule_unit, v_dom, v_first, finance.fn_recurring_valid_from(v_debit, v_disb), NULL, NULL, NULL);

        UPDATE finance.loans SET recurring_payment_id = v_rp_id WHERE id = v_loan_id;
    END IF;

    -- 4. Restschuld-Eroeffnung auf dem Loan-Konto (current_balance = aktuelle Restschuld;
    --    = original_amount bei frischem Kredit, < original_amount bei laufendem). Saldo via Trigger.
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, loan_id, description, group_id)
    VALUES (v_loan_acc, -v_current, v_disb, 'disbursement', v_loan_id,
            CASE WHEN v_current = v_amount THEN 'Kreditauszahlung ' || (p->>'name')
                 ELSE 'Restschuld ' || (p->>'name') || ' (bestehender Kredit)' END, v_group);

    -- 5. Auszahlungsbuchung auf das eigene Konto NUR wenn disbursement_account_id gesetzt ist
    --    (Kreditsumme floss tatsaechlich auf ein eigenes Konto). NULL = an Dritte/Verkaeufer
    --    oder laufender Kredit -> keine Buchung.
    IF v_disbursement_id IS NOT NULL THEN
        INSERT INTO finance.transactions
            (account_id, amount, transaction_date, category, loan_id, description, group_id)
        VALUES (v_disbursement_id, v_amount, v_disb, 'disbursement', v_loan_id, 'Kreditauszahlung ' || (p->>'name'), v_group);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'loan_id', v_loan_id,
        'card_lines', finance.fn_similar_note(v_sim),
        'loan_account_id', v_loan_acc,
        'debit_account_id', v_debit,
        'recurring_payment_id', v_rp_id
    );
END;
$$;
