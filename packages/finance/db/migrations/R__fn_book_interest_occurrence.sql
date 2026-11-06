-- ============================================================
-- fn_book_interest_occurrence (ATOMIC WRITE)
--   Bucht eine faellige Zinsgutschrift als echte Transaktion (category='interest') aufs Konto.
--   transaction_date = value_date (Buchungs-/Wertstellungsdatum, bei Arrears im Folgemonat),
--   interest_period_end = period_end (die abgedeckte Vorperiode = stabiler Idempotenz- + booked-Key).
--   "gebucht" ist damit aus finance.transactions ableitbar (keine eigene Status-Tabelle).
--   Eingabe jsonb: account_id, value_date, period_end, amount (optional Override = Nutzer-Ist; fehlt ->
--   DB-berechnet via fn_interest_amount_due(account_id, period_end), das LLM rechnet NIE).
--   Idempotenz-Guard: schon eine Zins-Tx fuer (account_id, period_end) -> {ok:false}. Abgleich-Sperre (Monats-Check
--   WP-A): value_date <= letzter Saldo-Abgleich -> {ok:false, code:'reconciled'} (fn_reconciled_reason). Korrigierbar
--   (amount<=0/0-Vorschlag) -> {ok:false} ohne RAISE. RUECKGABE: Erfolg -> {ok:true, transaction_id,
--   amount, account_balance} (Post-State).
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
    -- Korrigierbar: Zins nur auf Einlagen-Konten (cash/fixed_deposit/p2p). Depot/Kredit -> {ok:false}
    -- (schliesst das manuelle Buchungs-Loch; struktureller Backstop = trg_finance_reject_interest_rate_ineligible).
    IF NOT finance.fn_interest_eligible_account_type(v_acct_type) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Interest applies only to cash, fixed-deposit and P2P accounts (account type ' || v_acct_type || ' is not eligible).');
    END IF;
    -- value_date faellt auf das Perioden-Ende zurueck, falls nicht uebergeben (Same-period-Default).
    v_value := COALESCE(v_value, v_pend);

    -- Idempotenz: bereits eine Zinsbuchung fuer diese Periode (account_id, period_end)?
    IF EXISTS (SELECT 1 FROM finance.transactions
               WHERE account_id = v_acct AND category = 'interest' AND interest_period_end = v_pend) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Interest for account ' || v_acct || ' for the period ending ' || v_pend || ' is already booked.');
    END IF;

    v_reason := finance.fn_reconciled_reason(v_acct, v_value);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'reconciled', 'reason', v_reason);
    END IF;

    -- Betrag: Override (Nutzer-Ist) ODER DB-berechnet (basis x Satz x day-count-Anteil zum period_end).
    v_amount := COALESCE(v_override, finance.fn_interest_amount_due(v_acct, v_pend));

    -- Korrigierbar: positiver Betrag noetig (0/<=0 -> {ok:false}, kein RAISE, kein 0-EUR-Tx).
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

    -- WP-1 Race-Backstop: leeres RETURNING = ein gleichzeitiger Bucher hat das Rennen (TOCTOU) gewonnen -> {ok:false}.
    IF v_tx IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Interest for account ' || v_acct || ' for the period ending ' || v_pend || ' is already booked.');
    END IF;

    SELECT balance INTO v_bal FROM finance.account_balances WHERE account_id = v_acct;

    RETURN jsonb_build_object('ok', true, 'transaction_id', v_tx, 'amount', v_amount, 'account_balance', v_bal);
END;
$$;
