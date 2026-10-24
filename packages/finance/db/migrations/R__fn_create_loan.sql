-- ============================================================
-- fn_create_loan (ATOMIC WRITE)
--   Legt in EINER Transaktion an: (1) Loan-Konto, (2) Loan-Stammdaten, (3) optional
--   recurring_payment fuer die Monatsrate (nur wenn monthly_annuity gesetzt) + FK-Link,
--   (4) Restschuld-Eroeffnung auf dem Loan-Konto (-current_balance), (5) optionale
--   Auszahlungsbuchung (+original_amount) auf disbursement_account_id NUR wenn dieses gesetzt ist
--   (Kreditsumme floss auf ein eigenes Konto). NULL = an Dritte/Verkaeufer oder laufender
--   Kredit -> keine Auszahlungsbuchung. Eingabe als jsonb:
--     name, lender, borrower_person_id (Slug, NULL=Haushalt), original_amount, current_balance (aktuelle Restschuld),
--     disbursement_date, interest_rate, principal_rate (informativ), interest_rate_fixed_until, monthly_annuity,
--     schedule_day_of_month (1-28 | -1 Monatsletzter | -2 vorletzter Tag),
--     first_payment_date (echtes erstes/naechstes Ratendatum; PFLICHT, sobald monthly_annuity gesetzt ist),
--     disbursement_account_id (im n8n aufgeloest; NULL = keine Auszahlungsbuchung),
--     debit_account_id (Rate; im n8n aufgeloest), real_estate_id (optional)
--   FRISCH vs. LAUFEND (Live-Befund 2026-10-24, "die Rate ist die Wahrheit"):
--     * frisch  = current_balance leer oder = original_amount: original_amount + disbursement_date Pflicht; die
--       Eroeffnung (-original_amount) bucht zum disbursement_date.
--     * laufend = current_balance gesetzt und original_amount leer oder groesser: Pflicht nur Restschuld, Zins,
--       Abbuchungskonto (+ Rate mit naechster Faelligkeit); original_amount / disbursement_date / principal_rate sind
--       informativ. Die Eroeffnung (-current_balance) bucht zum Stichtag HEUTE (core.fn_today()) und setzt
--       accounts.opening_balance_date des Kreditkontos (Analog fn_create_account) -> fn_get_balance_as_of vor heute = 0,
--       ein Stichtags-Abgleich gegen einen alten Darlehensauszug sieht nicht schon die heutige Restschuld. Bewusst
--       KEIN waehlbarer Stichtag: Raten zwischen einem vergangenen Stichtag und heute fielen sonst durch das
--       90-Tage-Fenster bzw. den Konto-Stichtag des Abbuchungskontos -> Restschuld still zu hoch.
--   Die Raten-recurring_payment gilt fruehestens ab dem Eroeffnungssaldo-Stichtag des Abbuchungskontos UND des
--   Kreditkontos (fn_recurring_valid_from, die eine Regel): fruehere Raten stecken schon im genannten Kontostand bzw.
--   in der Restschuld; first_payment_date bleibt Anker.
--   Kredit-Betraege sind EUR nach Modell (das Kredit-Konto traegt die Default-Waehrung) -> Abbuchungs- und
--   Auszahlungskonto in Fremdwaehrung werden abgelehnt.
--   RUECKGABE: {ok:true, loan_id, loan_account_id, debit_account_id, recurring_payment_id, remaining_debt (Restschuld
--   nach dem Saldo-Trigger, positiv), disbursement_balance (Saldo des Auszahlungskontos nach der Buchung, sonst NULL),
--   opening_balance_date (Stichtag des laufenden Kredits, sonst NULL), first_rate_interest / first_rate_principal
--   (DB-gerechnete Aufteilung der 1. Rate aus der Restschuld: fn_loan_monthly_interest, Tilgung = Rate - Zins; ohne
--   Rate NULL), card_lines} | {ok:false, reason}
--   OHNE Write: Buchungstag, Zinssatz fehlt/negativ, Betrag <= 0, Rate <= 0, Rate ohne first_payment_date, frischer Kredit ohne Betrag oder
--   Auszahlungsdatum, current_balance <= 0 oder > original_amount, Auszahlungskonto bei laufendem Kredit (current <
--   original oder ohne original -> die Auszahlung liegt in der Vergangenheit und steckt schon im Kontostand), Rate
--   unter dem Monatszins der Restschuld ({interest, payment}; jede Buchung scheiterte sonst an
--   fn_get_loan_payment_split), Konto nicht EUR, Abbuchungs-/Auszahlungskonto nicht buchbar (Depot/Kredit: Rate
--   bliebe ewig offen bzw. die Auszahlung scheiterte am Kontotyp-Trigger).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_loan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_loan_acc INT;
    v_loan_id  INT;
    v_rp_id    INT;
    v_amount   NUMERIC  := NULLIF(p->>'original_amount', '')::numeric;
    v_current  NUMERIC  := COALESCE(NULLIF(p->>'current_balance', '')::numeric, NULLIF(p->>'original_amount', '')::numeric);
    v_disb     DATE     := NULLIF(p->>'disbursement_date', '')::date;
    v_irate    NUMERIC  := NULLIF(p->>'interest_rate', '')::numeric;
    v_annuity  NUMERIC  := NULLIF(p->>'monthly_annuity', '')::numeric;
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_first    DATE     := NULLIF(p->>'first_payment_date', '')::date;
    v_debit    INT      := (p->>'debit_account_id')::int;
    v_disbursement_id INT := NULLIF(p->>'disbursement_account_id', '')::int;
    v_group     UUID    := gen_random_uuid();   -- Multi-Leg: Restschuld-Eroeffnung + Auszahlung teilen eine group_id
    v_running   BOOLEAN;
    v_open_date DATE;                            -- Stichtag der Eroeffnung bei laufendem Kredit (heute), sonst NULL
    v_interest  NUMERIC;
    v_from      DATE;
    v_reason    TEXT;
    v_sim       TEXT;
BEGIN
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_irate IS NULL OR v_irate < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The annual interest rate (interest_rate, in percent) is required and must not be negative'
                   || COALESCE(', got ' || v_irate, '') || '.');
    END IF;
    -- Restschuld-Grenzen VOR der Frisch/Laufend-Unterscheidung (sonst verdeckte "Restschuld > Kreditbetrag" den Grund)
    IF v_current <= 0 OR v_current > v_amount THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The remaining debt (current_balance ' || v_current || ') must be greater than 0'
                   || COALESCE(' and not above the original amount (' || v_amount || ')', '') || '.');
    END IF;
    v_running := NULLIF(p->>'current_balance', '') IS NOT NULL AND (v_amount IS NULL OR v_current < v_amount);
    IF NOT v_running AND (v_amount IS NULL OR v_disb IS NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A new loan needs the loan amount (original_amount) and the payout date (disbursement_date). '
                   || 'For a loan that is already being repaid give today''s remaining debt (current_balance) instead.');
    END IF;
    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loan amount (original_amount) must be a positive number, got ' || v_amount || '.');
    END IF;
    IF v_annuity IS NOT NULL AND v_annuity <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Monthly annuity must be a positive number when given, got ' || v_annuity || '.');
    END IF;
    IF v_annuity IS NOT NULL AND v_first IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The date of the first (for a running loan: the next) rate debit (first_payment_date) is required when a monthly rate is given.');
    END IF;
    IF v_disbursement_id IS NOT NULL AND v_running THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'For a loan that is already being repaid, the payout happened in the past and is part of today''s account balance - leave the disbursement account empty.');
    END IF;
    IF EXISTS (SELECT 1 FROM finance.accounts WHERE id IN (v_debit, v_disbursement_id) AND currency <> 'EUR') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loan amounts are kept in EUR - the debit and payout accounts must be EUR accounts.');
    END IF;
    v_reason := COALESCE(finance.fn_bookable_account_reason(v_debit), finance.fn_bookable_account_reason(v_disbursement_id),
                         -- numeric(6,4) kuerzte > 4 Nachkommastellen still (Rundungs-Paket 2026-10-23)
                         finance.fn_rate_precision_reason(v_irate, 'Interest rate'),
                         finance.fn_rate_precision_reason(NULLIF(p->>'principal_rate', '')::numeric, 'Principal rate'));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Die Rate muss den Monatszins der Restschuld decken (dieselbe Formel wie jede Buchung, fn_get_loan_payment_split).
    v_interest := finance.fn_loan_monthly_interest(v_current, v_irate);
    IF v_annuity IS NOT NULL AND v_annuity < v_interest THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The monthly rate ' || v_annuity || ' does not cover the monthly interest ' || v_interest
                   || ' on the remaining debt ' || v_current || ' - check the rate, the interest rate and the remaining debt.',
            'interest', v_interest, 'payment', v_annuity);
    END IF;
    v_open_date := CASE WHEN v_running THEN core.fn_today() END;

    -- 1. Loan-Konto (negativer Saldo = Restschuld; balance-Zeile via Trigger). Laufend: Stichtag der Restschuld.
    INSERT INTO finance.accounts (name, account_type, bank, status, opening_balance_date)
    VALUES ('Kredit ' || (p->>'name'), 'loan', NULLIF(p->>'lender', ''), 'active', v_open_date)
    RETURNING id INTO v_loan_acc;

    -- Karten-Hinweis (hohe Schwelle): laufender Kredit (aktiv oder pausiert) bei derselben Bank mit gleichem
    -- Auszahlungsbetrag bzw. -- ohne Betrag -- gleicher Rate
    SELECT l.name INTO v_sim FROM finance.loans l
     WHERE l.status IN ('active', 'paused') AND NULLIF(btrim(p->>'lender'), '') IS NOT NULL
       AND lower(btrim(l.lender)) = lower(btrim(p->>'lender'))
       AND (l.original_amount = v_amount OR (v_amount IS NULL AND l.monthly_annuity = v_annuity))
     ORDER BY l.id LIMIT 1;

    -- 2. Loan-Stammdaten
    INSERT INTO finance.loans
        (name, lender, borrower_person_id, original_amount, disbursement_date,
         interest_rate, principal_rate, interest_rate_fixed_until,
         monthly_annuity, schedule_day_of_month, status,
         loan_account_id, debit_account_id, disbursement_account_id, real_estate_id)
    VALUES (p->>'name', NULLIF(p->>'lender', ''), NULLIF(p->>'borrower_person_id', ''), v_amount, v_disb,   -- WS-4: typisierter Kreditnehmer (Slug); NULL=Haushalt.
            v_irate, NULLIF(p->>'principal_rate', '')::numeric,
            NULLIF(p->>'interest_rate_fixed_until', '')::date,
            v_annuity, v_dom,
            CASE WHEN v_annuity IS NOT NULL THEN 'active' ELSE 'paused' END::finance.loan_status,
            v_loan_acc, v_debit, v_disbursement_id, NULLIF(p->>'real_estate_id', '')::int)
    RETURNING id INTO v_loan_id;

    -- 3. Recurring-Payment fuer die Monatsrate (nur bei vorhandener Annuitaet) + FK-Link
    IF v_annuity IS NOT NULL THEN
        -- Gueltig ab dem spaeteren Stichtag von Abbuchungs- und Kreditkonto (die eine Regel fn_recurring_valid_from).
        v_from := COALESCE(v_disb, core.fn_today());
        v_from := GREATEST(finance.fn_recurring_valid_from(v_debit, v_from), finance.fn_recurring_valid_from(v_loan_acc, v_from));
        -- recurring_payment via gemeinsamen Helper (Teil 0: eine Quelle fuer den Insert).
        v_rp_id := finance.fn_add_recurring_payment(
            v_debit, -v_annuity, 'Kreditrate ' || (p->>'name'),
            1::smallint, 'month'::finance.schedule_unit, v_dom, v_first, v_from, NULL, NULL, NULL);

        UPDATE finance.loans SET recurring_payment_id = v_rp_id WHERE id = v_loan_id;
    END IF;

    -- 4. Restschuld-Eroeffnung auf dem Loan-Konto: frisch = -original_amount zum Auszahlungsdatum,
    --    laufend = -current_balance zum Stichtag heute. Saldo via Trigger.
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, loan_id, description, group_id)
    VALUES (v_loan_acc, -v_current, COALESCE(v_open_date, v_disb), 'disbursement', v_loan_id,
            CASE WHEN v_running THEN 'Restschuld ' || (p->>'name') || ' (bestehender Kredit)'
                 ELSE 'Kreditauszahlung ' || (p->>'name') END, v_group);

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
        'recurring_payment_id', v_rp_id,
        'remaining_debt', (SELECT -balance FROM finance.account_balances WHERE account_id = v_loan_acc),
        'disbursement_balance', (SELECT balance FROM finance.account_balances WHERE account_id = v_disbursement_id),
        'opening_balance_date', v_open_date,
        'first_rate_interest', CASE WHEN v_annuity IS NOT NULL THEN v_interest END,
        'first_rate_principal', v_annuity - v_interest
    );
END;
$$;
