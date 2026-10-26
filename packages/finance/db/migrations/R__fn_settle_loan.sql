-- ============================================================
-- fn_settle_loan (ATOMIC WRITE) -- vorzeitige Abloesung / Sondertilgung auf Null
--   Bucht die komplette Abloesung in EINER Transaktion (2 Beine, gemeinsame group_id):
--   (1) Abbuchung vom Giro (-settlement_amount, category='settlement'),
--   (2) Tilgung der Restschuld auf das Kreditkonto (+remaining_debt, category='settlement') -> Saldo 0.
--   Implizit interest = settlement_amount - remaining_debt (Vorfaelligkeits-/Restzins). Danach
--   loan.status='paid_off' und die Rate-rp wird BEENDET (status='paused' + valid_to=settlement_date;
--   das valid_to nimmt sie aus dem Cashflow -- payment_status hat keinen eigenen 'ended'-Wert) ueber den
--   gemeinsamen Helfer fn_mark_loan_paid_off. Der Zustand davor (Kredit-Status, Raten-rp/-Status/-Ende) landet in
--   loans.settled_from -> fn_void_transaction stellt ihn exakt her.
--   KORRIGIERBAR (kein RAISE): keine Restschuld (already settled) bzw. settlement_amount < Restschuld
--     (Teilzahlung -> book_loan_payment) -> {ok:false, reason, remaining_debt}.
--   Eingabe jsonb: loan_name, debit_account_id (n8n-resolved), settlement_date,
--     settlement_amount (optional; default = Restschuld).
--   RUECKGABE: {ok:true, settlement_tx_id, principal_tx_id, remaining_debt, interest}.
--   RAISE nur bei not-found / mehrdeutig.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_settle_loan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name     TEXT := p->>'loan_name';
    v_debit    INT  := (p->>'debit_account_id')::int;
    v_date     DATE;
    v_amount   NUMERIC := NULLIF(p->>'settlement_amount', '')::numeric;
    v_resolve  RECORD;
    v_loan     finance.loans%ROWTYPE;
    v_rest     NUMERIC;
    v_interest NUMERIC;
    v_giro_tx  INT;
    v_prin_tx  INT;
    v_reason   TEXT;
    v_group    UUID := gen_random_uuid();
    v_dates    JSONB;
BEGIN
    -- relative Datumsangabe ("yesterday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}.
    -- Leer = heute in der Haushalts-Zeitzone (vorher CURRENT_DATE = Server-Zeitzone, Drift zu core.fn_today).
    v_dates := core.fn_resolve_input_dates(p, ARRAY['settlement_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'settlement_date', '')::date, core.fn_today());
    SELECT r.loan_id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_loan(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Loan "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple loans match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    SELECT * INTO v_loan FROM finance.loans WHERE id = v_resolve.loan_id;

    -- Korrigierbar (Audit Paket 2, Kontotyp): die Abloesung zahlt ein Geld-Konto, nie ein Depot oder Kreditkonto.
    v_reason := finance.fn_bookable_account_reason(v_debit);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- FOR UPDATE: Saldo-Zeile sperren (Cron ∥ Chat) -> kein TOCTOU zwischen Restschuld-Lesen und Buchen.
    SELECT GREATEST(-b.balance, 0) INTO v_rest
    FROM finance.account_balances b WHERE b.account_id = v_loan.loan_account_id
    FOR UPDATE OF b;

    -- Korrigierbar: keine Restschuld -> {ok:false}.
    IF COALESCE(v_rest, 0) <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loan has no outstanding debt (already settled / paid off).',
            'remaining_debt', COALESCE(v_rest, 0));
    END IF;

    v_amount := COALESCE(v_amount, v_rest);   -- Default = volle Restschuld (kein Zusatzzins)

    -- Korrigierbar: Betrag deckt die Restschuld nicht -> Teilzahlung, nicht Abloesung.
    IF v_amount < v_rest THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Settlement amount ' || v_amount || ' does not cover the remaining debt ' || v_rest
                   || '. Use book_loan_payment for a partial payment.',
            'remaining_debt', v_rest);
    END IF;

    v_interest := ROUND(v_amount - v_rest, 2);

    -- 1. Abbuchung vom Giro (volle Abloesesumme inkl. evtl. Restzins)
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, loan_id, description, group_id)
    VALUES (v_debit, -v_amount, v_date, 'settlement', v_loan.id,
            'Ablösung ' || v_loan.name || ' (Restschuld ' || v_rest || ' + Zins ' || v_interest || ')', v_group)
    RETURNING id INTO v_giro_tx;

    -- 2. Tilgung der Restschuld auf das Kreditkonto (Saldo -> 0)
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, loan_id, description, group_id)
    VALUES (v_loan.loan_account_id, v_rest, v_date, 'settlement', v_loan.id,
            'Ablösung Tilgung ' || v_loan.name, v_group)
    RETURNING id INTO v_prin_tx;

    -- 3. Kredit beendet + Rate beenden ueber den gemeinsamen Helfer (Audit Paket 2; vorheriger Zustand in
    --    settled_from -> Void stellt ihn exakt wieder her, inkl. vorher pausiert und vertraglichem Raten-Ende).
    PERFORM finance.fn_mark_loan_paid_off(v_loan.id, v_date);

    RETURN jsonb_build_object('ok', true,
        'settlement_tx_id', v_giro_tx, 'principal_tx_id', v_prin_tx,
        'remaining_debt', v_rest, 'interest', v_interest,
        'effective', (v_dates->'resolved') || jsonb_build_object('settlement_date', v_date));
END;
$$;
