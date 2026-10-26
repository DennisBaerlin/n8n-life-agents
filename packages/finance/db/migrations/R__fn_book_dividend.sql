-- ============================================================
-- fn_book_dividend (ATOMIC WRITE)
--   Ein INSERT (Dividende aufs Verrechnungskonto; shares=NULL laut CHECK) — als Function fuer
--   Einheitlichkeit. Eingabe jsonb: account_id, amount, transaction_date (ISO oder relativ, leer = heute), holding_id, description.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, transaction_id, account_balance} (Post-State:
--   neuer Saldo des gutgeschriebenen Kontos, in derselben Transaktion gelesen). Korrigierbar
--   (amount<=0) -> {ok:false, reason} OHNE Write (kein RAISE -> kein Owner-Alert).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_dividend(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_amount NUMERIC := (p->>'amount')::numeric;
    v_id     INT;
    v_bal    NUMERIC;
    v_dates  JSONB;
BEGIN
    -- relative Datumsangabe ("yesterday", "-3 days") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    -- Korrigierbar: Dividende muss positiv sein -> {ok:false} (kein RAISE).
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Dividend amount must be a positive number, got ' || COALESCE(v_amount::text, 'null') || '.');
    END IF;

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, holding_id, shares, description)
    VALUES ((p->>'account_id')::int, v_amount, COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today()), 'dividend',
            (p->>'holding_id')::int, NULL, p->>'description')
    RETURNING id INTO v_id;

    -- Post-State (Trigger hat gefeuert): neuer Saldo des gutgeschriebenen Kontos.
    SELECT balance INTO v_bal
    FROM finance.account_balances WHERE account_id = (p->>'account_id')::int;

    RETURN jsonb_build_object('ok', true, 'transaction_id', v_id, 'account_balance', v_bal,
        'effective', (v_dates->'resolved') || jsonb_build_object('transaction_date',
                         COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today())));
END;
$$;
