-- ============================================================
-- fn_create_loan (ATOMIC WRITE)
--   Legt in EINER Transaktion an: (1) Loan-Konto, (2) optional die Raten-Kette (recurring_payment, nur wenn
--   monthly_annuity gesetzt), (3) Loan-Stammdaten mit FK-Link, (4) Restschuld-Eroeffnung auf dem Loan-Konto
--   (-Restschuld), (5) optionale Auszahlungsbuchung (+original_amount) auf disbursement_account_id NUR wenn dieses gesetzt
--   ist (Kreditsumme floss auf ein eigenes Konto). Eingabe als jsonb:
--     name, lender, borrower_person_id (Slug, NULL=Haushalt), original_amount, current_balance (aktuelle Restschuld),
--     disbursement_date, interest_rate, interest_rate_fixed_until, term_end_date (Laufzeitende = Termin der letzten Rate;
--     bei Schlussrate deren Termin, Betrag in notes), monthly_annuity, schedule_day_of_month (1-28 | -1 | -2),
--     first_payment_date (echtes erstes/naechstes Ratendatum; PFLICHT, sobald monthly_annuity gesetzt ist), notes,
--     disbursement_account_id (im n8n aufgeloest; NULL = keine Auszahlungsbuchung),
--     debit_account_id (Rate; im n8n aufgeloest), real_estate_id (optional)
--   EINE QUELLE (WP2, finance:V026): Rate, Rhythmus und Abbuchungstag stehen nur an der Raten-Kette; die Kredit-Zeile
--   traegt keine Kopie. Die "anfaengliche Tilgung" wird nicht mehr erfasst (loan_overview.initial_principal_rate leitet
--   sie aus Kreditbetrag + erster Rate ab).
--   FRISCH vs. ERÖFFNUNG ZUM STICHTAG HEUTE (Live-Befunde 2026-10-24/25, "die Rate ist die Wahrheit"):
--     * frisch mit Auszahlungsbuchung bzw. mit genanntem Auszahlungsdatum: original_amount Pflicht; die Eroeffnung
--       (-original_amount) bucht zum disbursement_date; ein Auszahlungskonto braucht Betrag UND Datum.
--     * Eroeffnung zum Stichtag heute (core.fn_today(), accounts.opening_balance_date wie fn_create_account): laufender
--       Kredit (current_balance kleiner original_amount oder ohne original_amount) ODER frischer Kredit ohne Datum und
--       ohne eigenes Auszahlungskonto (Auszahlung an Dritte). Pflicht nur Restschuld, Zins, Abbuchungskonto (+ Rate mit
--       naechster Faelligkeit); original_amount / disbursement_date sind spaeter per fn_set_loan nachtragbar.
--       fn_get_balance_as_of vor heute = 0 -> ein Stichtags-Abgleich gegen einen alten Darlehensauszug sieht nicht schon
--       die heutige Restschuld. Bewusst KEIN waehlbarer Stichtag (Raten zwischen Stichtag und heute fielen sonst durch
--       das 90-Tage-Fenster -> Restschuld still zu hoch).
--   Die Raten-recurring_payment gilt fruehestens ab dem Eroeffnungssaldo-Stichtag des Abbuchungskontos UND des
--   Kreditkontos (fn_recurring_valid_from, die eine Regel): fruehere Raten stecken schon im genannten Kontostand bzw.
--   in der Restschuld; first_payment_date bleibt Anker.
--   Kredit-Betraege sind EUR nach Modell (das Kredit-Konto traegt die Default-Waehrung) -> Abbuchungs- und
--   Auszahlungskonto in Fremdwaehrung werden abgelehnt.
--   RUECKGABE: {ok:true, loan_id, loan_account_id, debit_account_id, recurring_payment_id, remaining_debt (Restschuld
--   nach dem Saldo-Trigger, positiv), disbursement_balance (Saldo des Auszahlungskontos nach der Buchung, sonst NULL),
--   opening_balance_date (Stichtag einer Eroeffnung zu heute, sonst NULL), first_rate_interest / first_rate_principal
--   (DB-gerechnete Aufteilung der 1. Rate aus der Restschuld: fn_loan_monthly_interest, Tilgung = Rate - Zins; ohne
--   Rate NULL), initial_principal_rate, balance_at_fixed_until, balance_at_term_end (aus loan_overview: rechnerische
--   anfaengliche Tilgung; voraussichtliche Restschuld zum Zinsbindungs-/Laufzeitende bei gleichem Zins, ohne
--   Sondertilgung), card_lines} | {ok:false, reason}
--   OHNE Write: Buchungstag, Zinssatz fehlt/negativ, Restschuld fehlt/<= 0/> original_amount, Betrag <= 0,
--   Auszahlungsdatum in der Zukunft, Auszahlungskonto ohne Betrag/Datum oder bei laufendem Kredit, Laufzeitende vor
--   Auszahlung oder vor dem Zinsbindungsende, Rate <= 0, Rate ohne first_payment_date, Rate unter dem Monatszins der
--   Restschuld ({interest, payment}; jede Buchung scheiterte sonst an fn_get_loan_payment_split), Konto nicht EUR,
--   Abbuchungs-/Auszahlungskonto nicht buchbar (Depot/Kredit).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_loan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_loan_acc INT;
    v_loan_id  INT;
    v_rp_id    INT;
    v_amount   NUMERIC  := NULLIF(p->>'original_amount', '')::numeric;
    v_current  NUMERIC  := COALESCE(NULLIF(p->>'current_balance', '')::numeric, NULLIF(p->>'original_amount', '')::numeric);
    v_disb     DATE;
    v_irate    NUMERIC  := NULLIF(p->>'interest_rate', '')::numeric;
    v_fixed    DATE;
    v_term_end DATE;
    v_annuity  NUMERIC  := NULLIF(p->>'monthly_annuity', '')::numeric;
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_first    DATE;
    v_debit    INT      := (p->>'debit_account_id')::int;
    v_disbursement_id INT := NULLIF(p->>'disbursement_account_id', '')::int;
    v_today     DATE    := core.fn_today();
    v_group     UUID    := gen_random_uuid();   -- Multi-Leg: Restschuld-Eroeffnung + Auszahlung teilen eine group_id
    v_running   BOOLEAN;                     -- laufender Kredit (Restschuld kleiner Kreditbetrag bzw. ohne Kreditbetrag)
    v_open_date DATE;                        -- Stichtag einer Eroeffnung zu heute, sonst NULL
    v_interest  NUMERIC;
    v_from      DATE;
    v_reason    TEXT;
    v_sim       TEXT;
    v_ov        RECORD;
    v_dates     JSONB;
BEGIN
    -- relative Datumsangaben ("in 2 weeks", "+10 years") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p,
                   ARRAY['disbursement_date', 'interest_rate_fixed_until', 'term_end_date', 'first_payment_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_disb     := NULLIF(p->>'disbursement_date', '')::date;
    v_fixed    := NULLIF(p->>'interest_rate_fixed_until', '')::date;
    v_term_end := NULLIF(p->>'term_end_date', '')::date;
    v_first    := NULLIF(p->>'first_payment_date', '')::date;
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
    IF v_current IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The remaining debt is required: today''s remaining debt (current_balance) for a loan that is already '
                   || 'being repaid, or the loan amount (original_amount) for a new loan.');
    END IF;
    -- Restschuld-Grenzen VOR der Frisch/Laufend-Unterscheidung (sonst verdeckte "Restschuld > Kreditbetrag" den Grund)
    IF v_current <= 0 OR v_current > v_amount THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The remaining debt (current_balance ' || v_current || ') must be greater than 0'
                   || COALESCE(' and not above the original amount (' || v_amount || ')', '') || '.');
    END IF;
    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loan amount (original_amount) must be a positive number, got ' || v_amount || '.');
    END IF;
    IF v_disb > v_today THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The payout date (disbursement_date ' || v_disb || ') lies in the future - record the loan once it has been paid out.');
    END IF;
    v_running := NULLIF(p->>'current_balance', '') IS NOT NULL AND (v_amount IS NULL OR v_current < v_amount);
    IF v_disbursement_id IS NOT NULL AND v_running THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'For a loan that is already being repaid, the payout happened in the past and is part of today''s account balance - leave the disbursement account empty.');
    END IF;
    IF v_disbursement_id IS NOT NULL AND (v_amount IS NULL OR v_disb IS NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A payout into one of your own accounts needs the loan amount (original_amount) and the payout date (disbursement_date).');
    END IF;
    -- Eroeffnung zum Stichtag heute: laufend, oder frisch ohne Datum (Auszahlung an Dritte; Datum spaeter nachtragbar)
    IF v_running OR v_disb IS NULL THEN
        v_open_date := v_today;
    END IF;
    -- Laufzeit-Guards (Spiegel von CHECK finance_loans_term_end_chk)
    IF v_term_end IS NOT NULL AND (v_term_end < v_disb OR v_term_end < v_fixed) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The end of the term (term_end_date ' || v_term_end || ') must not be before the payout date'
                   || ' or the end of the fixed-interest period (interest_rate_fixed_until).');
    END IF;
    IF v_annuity IS NOT NULL AND v_annuity <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Monthly annuity must be a positive number when given, got ' || v_annuity || '.');
    END IF;
    IF v_annuity IS NOT NULL AND v_first IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The date of the first (for a running loan: the next) rate debit (first_payment_date) is required when a monthly rate is given.');
    END IF;
    IF EXISTS (SELECT 1 FROM finance.accounts WHERE id IN (v_debit, v_disbursement_id) AND currency <> 'EUR') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loan amounts are kept in EUR - the debit and payout accounts must be EUR accounts.');
    END IF;
    v_reason := COALESCE(finance.fn_bookable_account_reason(v_debit), finance.fn_bookable_account_reason(v_disbursement_id),
                         -- numeric(6,4) kuerzte > 4 Nachkommastellen still (Rundungs-Paket 2026-10-23)
                         finance.fn_rate_precision_reason(v_irate, 'Interest rate'));
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

    -- 1. Loan-Konto (negativer Saldo = Restschuld; balance-Zeile via Trigger). Eroeffnung zu heute: Stichtag.
    INSERT INTO finance.accounts (name, account_type, bank, status, opening_balance_date)
    VALUES (left('Kredit ' || (p->>'name'), 100), 'loan', NULLIF(p->>'lender', ''), 'active', v_open_date)
    RETURNING id INTO v_loan_acc;

    -- Karten-Hinweis (hohe Schwelle): laufender Kredit (aktiv oder pausiert) bei derselben Bank mit gleichem
    -- Auszahlungsbetrag bzw. -- ohne Betrag -- gleicher aktueller Rate (aus der Raten-Kette)
    SELECT l.name INTO v_sim FROM finance.loans l
      LEFT JOIN finance.recurring_payments rc ON rc.id = finance.fn_recurring_current(l.recurring_payment_id, v_today)
     WHERE l.status IN ('active', 'paused') AND NULLIF(btrim(p->>'lender'), '') IS NOT NULL
       AND lower(btrim(l.lender)) = lower(btrim(p->>'lender'))
       AND (l.original_amount = v_amount OR (v_amount IS NULL AND abs(rc.amount) = v_annuity))
     ORDER BY l.id LIMIT 1;

    -- 2. Raten-Kette (nur bei vorhandener Rate) VOR dem Kredit: CHECK "aktiv <=> Raten-Kette" (finance:V026)
    IF v_annuity IS NOT NULL THEN
        -- Gueltig ab dem spaeteren Stichtag von Abbuchungs- und Kreditkonto (die eine Regel fn_recurring_valid_from).
        v_from := COALESCE(v_disb, v_today);
        v_from := GREATEST(finance.fn_recurring_valid_from(v_debit, v_from), finance.fn_recurring_valid_from(v_loan_acc, v_from));
        v_rp_id := finance.fn_add_recurring_payment(
            v_debit, -v_annuity, left('Kreditrate ' || (p->>'name'), 100),
            1::smallint, 'month'::finance.schedule_unit, v_dom, v_first, v_from, NULL, NULL, NULL);
    END IF;

    -- 3. Loan-Stammdaten
    INSERT INTO finance.loans
        (name, lender, borrower_person_id, original_amount, disbursement_date,
         interest_rate, interest_rate_fixed_until, term_end_date, status, notes,
         loan_account_id, debit_account_id, disbursement_account_id, real_estate_id, recurring_payment_id)
    VALUES (p->>'name', NULLIF(p->>'lender', ''), NULLIF(p->>'borrower_person_id', ''), v_amount, v_disb,   -- WS-4: typisierter Kreditnehmer (Slug); NULL=Haushalt.
            v_irate, v_fixed, v_term_end,
            CASE WHEN v_annuity IS NOT NULL THEN 'active' ELSE 'paused' END::finance.loan_status,
            NULLIF(p->>'notes', ''),
            v_loan_acc, v_debit, v_disbursement_id, NULLIF(p->>'real_estate_id', '')::int, v_rp_id)
    RETURNING id INTO v_loan_id;

    -- 4. Restschuld-Eroeffnung auf dem Loan-Konto: frisch = -original_amount zum Auszahlungsdatum, sonst
    --    -Restschuld zum Stichtag heute. Saldo via Trigger.
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

    SELECT initial_principal_rate, balance_at_fixed_until_projected, balance_at_term_end_projected
      INTO v_ov FROM finance.loan_overview WHERE id = v_loan_id;

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
        'first_rate_principal', v_annuity - v_interest,
        'initial_principal_rate', v_ov.initial_principal_rate,
        'balance_at_fixed_until', v_ov.balance_at_fixed_until_projected,
        'balance_at_term_end', v_ov.balance_at_term_end_projected,
        'effective', v_dates->'resolved'
    );
END;
$$;
