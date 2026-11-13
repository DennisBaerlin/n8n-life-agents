-- ============================================================
-- fn_book_dividend (ATOMIC WRITE)
--   Bucht eine Dividende aufs Verrechnungskonto (category='dividend', shares=NULL laut CHECK).
--   Eingabe jsonb: account_id, amount (Pflicht, > 0), transaction_date (optional, ISO oder relativ, leer = heute),
--   holding_id, description (optional).
--   Rueckgabe: ok:true -> {ok:true, transaction_id, account_balance (neuer Saldo des Kontos, nach dem Trigger
--   gelesen), effective (aufgeloeste Datumsangaben inkl. transaction_date)}. ok:false ohne Write und ohne RAISE:
--   {reason} bei amount <= 0 oder NULL; {code:'invalid_date'} bei nicht aufloesbarem Datum.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_dividend(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_amount NUMERIC := (p->>'amount')::numeric;
    v_id     INT;
    v_bal    NUMERIC;
    v_dates  JSONB;
BEGIN
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Dividend amount must be a positive number, got ' || COALESCE(v_amount::text, 'null') || '.');
    END IF;

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, holding_id, shares, description)
    VALUES ((p->>'account_id')::int, v_amount, COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today()), 'dividend',
            (p->>'holding_id')::int, NULL, p->>'description')
    RETURNING id INTO v_id;

    SELECT balance INTO v_bal
    FROM finance.account_balances WHERE account_id = (p->>'account_id')::int;

    RETURN jsonb_build_object('ok', true, 'transaction_id', v_id, 'account_balance', v_bal,
        'effective', (v_dates->'resolved') || jsonb_build_object('transaction_date',
                         COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today())));
END;
$$;
