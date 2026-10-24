-- ============================================================
-- fn_book_stock_sell (ATOMIC WRITE)
--   EINE Verkaufs-Transaktion auf das Verrechnungskonto. Order-Gebuehr
--   wird in amount gefaltet (mindert den Erloes) UND separat in order_fee
--   gespeichert; shares-Delta ist negativ (-verkaufte Stuecke). avg-Trigger
--   liest nur buy -> Sell-Gebuehr verfaelscht avg nie.
--   Eingabe jsonb: settlement_id, holding_id, shares (positiver Eingabewert),
--   price_per_share, order_fee, transaction_date, symbol (fuer description).
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, sell_tx_id, settlement_balance, proceeds,
--   remaining_shares} (Post-State aus der fn: neuer Verrechnungskonto-Saldo + Netto-Erloes
--   + Trigger-gepflegte Rest-Stuecke, in derselben Transaktion gelesen). Korrigierbarer Fall
--   (oversell / nicht-positive Werte / negative Gebuehr / > 8 Stueck-Stellen oder Erloes <= 0 Cent via
--   fn_trade_amount_reason) -> {ok:false, reason, ...} OHNE Write
--   (kein RAISE -> kein Owner-Alert; das Tool reicht reason an den Agenten).
--   RAISE nur fuer echte Ausnahmen (Holding-not-found = Tool faengt es vor dem Gate ab).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_stock_sell(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_settle  INT     := (p->>'settlement_id')::int;
    v_holding INT     := (p->>'holding_id')::int;
    v_shares  NUMERIC := (p->>'shares')::numeric;           -- positiver Eingabewert
    v_price   NUMERIC := (p->>'price_per_share')::numeric;
    v_fee     NUMERIC := COALESCE(NULLIF(p->>'order_fee', '')::numeric, 0);
    v_date    DATE    := COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today());   -- leer = heute (DB-Default)
    v_avail   NUMERIC;
    v_sell    INT;
    v_bal     NUMERIC;
    v_remain  NUMERIC;
    v_reason  TEXT;
    v_proceeds NUMERIC;
BEGIN
    -- Gebuehr auf Cent (order_fee numeric(12,2)): Betrag und order_fee entstehen aus demselben Wert (Rundungs-Paket).
    v_fee := round(v_fee, 2);
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_fee < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Order fee must not be negative, got ' || v_fee || '.');
    END IF;
    IF v_shares IS NULL OR v_shares <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Share count must be a positive number, got ' || COALESCE(v_shares::text, 'null') || '.');
    END IF;
    IF v_price IS NULL OR v_price <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Price per share must be a positive number, got ' || COALESCE(v_price::text, 'null') || '.');
    END IF;
    -- Rundungs-Paket 2026-10-23: > 8 Stueck-Stellen / Erloes nach Gebuehr <= 0 Cent -> {ok:false} (vorher CHECK-RAISE
    -- sell amount>0 mit Owner-Alert); EINE Adresse mit fn_book_stock_buy.
    v_reason := finance.fn_trade_amount_reason(v_shares, v_shares * v_price - v_fee);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- Holding-not-found bleibt RAISE-Backstop (Tool faengt es vor dem Gate ab).
    -- FOR UPDATE: Holding-Zeile sperren (Cron ∥ Chat) -> kein TOCTOU zwischen Oversell-Pruefung und Insert.
    SELECT shares INTO v_avail FROM finance.depot_holdings WHERE id = v_holding FOR UPDATE;
    IF v_avail IS NULL THEN
        RAISE EXCEPTION 'Holding % not found.', v_holding;
    END IF;

    -- Oversell -> korrigierbar (Agent fragt nach, wie viele verkauft werden sollen).
    IF v_shares > v_avail THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Cannot sell ' || v_shares || ' shares: only ' || v_avail
                   || ' available in this holding. Ask the user how many to sell (max ' || v_avail || ').',
            'available', v_avail,
            'requested', v_shares);
    END IF;

    -- EINE Verkaufs-Transaktion (Gebuehr in amount gefaltet + separat in order_fee).
    -- amount positiv (credit zum Settlement-Konto); shares negativ (Anteile gehen weg).
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description)
    VALUES (
        v_settle,
        (v_shares * v_price) - v_fee,
        v_date,
        'sell',
        v_holding,
        -v_shares,
        v_fee,
        'Verkauf ' || (p->>'shares') || ' ' || COALESCE(NULLIF(p->>'symbol', ''), 'Papier') ||
        ' @ ' || (p->>'price_per_share') || ' (Gebühr ' || COALESCE(p->>'order_fee', '0') || ')'
    )
    RETURNING id, amount INTO v_sell, v_proceeds;   -- proceeds = der GEBUCHTE Cent-Betrag (vorher ungerundet)

    -- Post-State (Trigger haben gefeuert): Verrechnungskonto-Saldo + Rest-Stuecke.
    SELECT balance INTO v_bal
    FROM finance.account_balances WHERE account_id = v_settle;
    SELECT shares INTO v_remain
    FROM finance.depot_holdings WHERE id = v_holding;

    RETURN jsonb_build_object('ok', true, 'sell_tx_id', v_sell,
        'settlement_balance', v_bal,
        'proceeds', v_proceeds,
        'remaining_shares', v_remain,
        'effective', jsonb_build_object('transaction_date', v_date, 'order_fee', v_fee));
END;
$$;
