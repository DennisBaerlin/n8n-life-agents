-- ============================================================
-- fn_book_interest_occurrence (ATOMIC WRITE)
--   Bucht eine faellige Zinsgutschrift als echte Transaktion (category='interest') aufs Konto.
--   transaction_date = value_date (Buchungs-/Wertstellungsdatum, bei Arrears im Folgemonat),
--   interest_period_end = period_end (die abgedeckte Vorperiode = stabiler Idempotenz- + booked-Key).
--   "gebucht" ist damit aus finance.transactions ableitbar (keine eigene Status-Tabelle).
--   Eingabe jsonb: account_id, period_end (Pflicht, sonst RAISE), value_date (optional, Default period_end),
--   amount (optional Override = Nutzer-Ist; fehlt -> DB-berechnet via fn_interest_amount_due(account_id, period_end)).
--   Rueckgabe: ok:true -> {ok:true, transaction_id, amount, account_balance (Post-State)}.
--   ok:false ohne RAISE: {reason} bei Kontotyp ohne Zins (nur cash/fixed_deposit/p2p) oder Betrag <= 0 / 0-Vorschlag;
--   {code:'already_booked'} wenn fuer (account_id, period_end) schon eine Zins-Tx existiert;
--   {code:'reconciled'} wenn value_date <= letzter Saldo-Abgleich (fn_reconciled_reason).
--   RAISE bei unbekanntem Konto.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_interest_occurrence(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_acct     INT  := (p->>'account_id')::int;
    v_value    DATE := (p->>'value_date')::date;
    v_pend     DATE := (p->>'period_end')::date;
    v_override NUMERIC := NULLIF(p->>'amount', '')::numeric;
    v_amount   NUMERIC;
    v_acct_type finance.account_type;
    v_tx       INT;
    v_bal      NUMERIC;
    v_reason   TEXT;
BEGIN
    SELECT account_type INTO v_acct_type FROM finance.accounts WHERE id = v_acct;
    IF v_acct_type IS NULL THEN
        RAISE EXCEPTION 'Account % not found.', v_acct;
    END IF;
    IF v_pend IS NULL THEN
        RAISE EXCEPTION 'period_end is required for interest booking.';
    END IF;
    -- Struktureller Backstop: trg_finance_reject_interest_rate_ineligible.
    IF NOT finance.fn_interest_eligible_account_type(v_acct_type) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Interest applies only to cash, fixed-deposit and P2P accounts (account type ' || v_acct_type || ' is not eligible).');
    END IF;
    v_value := COALESCE(v_value, v_pend);

    IF EXISTS (SELECT 1 FROM finance.transactions
               WHERE account_id = v_acct AND category = 'interest' AND interest_period_end = v_pend) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Interest for account ' || v_acct || ' for the period ending ' || v_pend || ' is already booked.');
    END IF;

    v_reason := finance.fn_reconciled_reason(v_acct, v_value);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'reconciled', 'reason', v_reason);
    END IF;

    v_amount := COALESCE(v_override, finance.fn_interest_amount_due(v_acct, v_pend));

    -- Kein 0-EUR-Tx: ein 0-Vorschlag der DB ist eine Ablehnung, kein Write.
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Interest amount must be a positive number, got ' || COALESCE(v_amount::text, 'null') || '.');
    END IF;

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, interest_period_end, description)
    VALUES (v_acct, v_amount, v_value, 'interest', v_pend, 'Zinsgutschrift ' || v_pend)
    ON CONFLICT (account_id, interest_period_end) WHERE category = 'interest' AND interest_period_end IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_tx;

    -- Race-Backstop: leeres RETURNING = ein gleichzeitiger Bucher war schneller (TOCTOU zum EXISTS oben).
    IF v_tx IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Interest for account ' || v_acct || ' for the period ending ' || v_pend || ' is already booked.');
    END IF;

    SELECT balance INTO v_bal FROM finance.account_balances WHERE account_id = v_acct;

    RETURN jsonb_build_object('ok', true, 'transaction_id', v_tx, 'amount', v_amount, 'account_balance', v_bal);
END;
$$;
