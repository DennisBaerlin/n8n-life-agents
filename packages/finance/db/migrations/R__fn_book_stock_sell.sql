-- ============================================================
-- fn_book_stock_sell (ATOMIC WRITE)
--   EINE Verkaufs-Transaktion auf das Verrechnungskonto. Order-Gebuehr
--   wird in amount gefaltet (mindert den Erloes) UND separat in order_fee
--   gespeichert; shares-Delta ist negativ (-verkaufte Stuecke). avg-Trigger
--   liest nur buy -> Sell-Gebuehr verfaelscht avg nie.
--   Eingabe jsonb: settlement_id, holding_id, shares (positiver Eingabewert),
--   price_per_share, order_fee, transaction_date (ISO oder relativ, leer = heute), symbol (fuer description).
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, sell_tx_id, settlement_balance, proceeds,
--   remaining_shares} (Post-State aus der fn: neuer Verrechnungskonto-Saldo + Netto-Erloes
--   + Trigger-gepflegte Rest-Stuecke, in derselben Transaktion gelesen). Korrigierbarer Fall
--   (oversell / nicht-positive Werte / negative Gebuehr / > 8 Stueck-Stellen oder Erloes <= 0 Cent via
--   fn_trade_amount_reason) -> {ok:false, reason, ...} OHNE Write
--   (kein RAISE -> kein Owner-Alert; das Tool reicht reason an den Agenten).
--   RAISE nur fuer echte Ausnahmen (Holding-not-found = Tool faengt es vor dem Gate ab).
--   UMSCHICHTEN FUER EIN SPARZIEL (Sparziel-Zweckbindung 2026-10-27, Umschicht-Hilfe vor dem Zieldatum): optional
--   savings_goal_name (aktives Ziel, fn_resolve_savings_goal). Dann haengt die fn zwei Journal-Zeilen kind='derisk'
--   an (source_tx_id = Verkauf, value_date = Verkaufsdatum, Waehrung des Verrechnungskontos = Depot-Waehrung): Depot -m,
--   Verrechnungskonto +m, m = min(Depot-Anteil des Ziels, Erloes) -> das Geld liegt danach als Ziel-Geld auf dem
--   Konto, der Fortschritt bleibt gleich; ein Void storniert beide (fn_void_transaction). Korrigierbar: Ziel nicht
--   eindeutig, kein Geld des Ziels in diesem Depot, Waehrung Verrechnungskonto != Depot, fehlender FX-Kurs ->
--   {ok:false} ohne Verkauf. Rueckgabe dann zusaetzlich derisk_amount (m) und current_amount (Ziel-Stand EUR).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_stock_sell(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_settle  INT     := (p->>'settlement_id')::int;
    v_holding INT     := (p->>'holding_id')::int;
    v_shares  NUMERIC := (p->>'shares')::numeric;           -- positiver Eingabewert
    v_price   NUMERIC := (p->>'price_per_share')::numeric;
    v_fee     NUMERIC := COALESCE(NULLIF(p->>'order_fee', '')::numeric, 0);
    v_date    DATE;
    v_avail   NUMERIC;
    v_sell    INT;
    v_bal     NUMERIC;
    v_remain  NUMERIC;
    v_reason  TEXT;
    v_proceeds NUMERIC;
    v_dates   JSONB;
    v_goal_name TEXT := NULLIF(btrim(p->>'savings_goal_name'), '');
    v_goal_res RECORD;
    v_goal    INT;
    v_depot   INT;
    v_dccy    TEXT;
    v_sccy    TEXT;
    v_dshare  NUMERIC;   -- Depot-Anteil des Ziels in EUR
    v_rate    NUMERIC;   -- Depot-Waehrung je EUR am Verkaufsdatum (Erloes / Erloes in EUR)
    v_m       NUMERIC;   -- umgeschichteter Betrag (Depot-/Settlement-Waehrung)
    v_cur     NUMERIC;
BEGIN
    -- relative Datumsangabe ("yesterday", "-3 days") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today());   -- leer = heute (DB-Default)
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

    -- Umschichten fuer ein Sparziel: alles VOR dem Write pruefen (Ziel, Ziel-Geld im Depot, Waehrung, Kurs).
    IF v_goal_name IS NOT NULL THEN
        SELECT r.id, r.hit_count INTO v_goal_res FROM finance.fn_resolve_savings_goal(v_goal_name, TRUE) r;
        IF v_goal_res.hit_count IS DISTINCT FROM 1 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Savings goal "' || v_goal_name || '" resolves to ' || COALESCE(v_goal_res.hit_count, 0)
                       || ' active goals - ask the user which goal the sale belongs to.');
        END IF;
        v_goal := v_goal_res.id;
        SELECT h.account_id, a.currency INTO v_depot, v_dccy
        FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id WHERE h.id = v_holding;
        SELECT currency INTO v_sccy FROM finance.accounts WHERE id = v_settle;
        IF v_sccy IS DISTINCT FROM v_dccy THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Cross-currency goal-linked sale not supported: the settlement account is ' || COALESCE(v_sccy, '?')
                       || ' but the depot is ' || COALESCE(v_dccy, '?') || '. Book the sale without the savings goal.');
        END IF;
        SELECT share_eur INTO v_dshare FROM finance.savings_goal_account_share WHERE goal_id = v_goal AND account_id = v_depot;
        IF COALESCE(v_dshare, 0) <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Savings goal "' || v_goal_name || '" has no money in this depot - book the sale without the goal, '
                       || 'or earmark the money first (tool_book_savings_reservation).');
        END IF;
        v_proceeds := round(v_shares * v_price - v_fee, 2);
        v_rate := v_proceeds / NULLIF(finance.fn_to_eur(v_proceeds, v_sccy, v_date), 0);
        IF v_rate IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'No exchange rate for ' || v_sccy || ' on ' || v_date || ' - the goal share cannot be moved.');
        END IF;
        v_m := round(LEAST(v_dshare * v_rate, v_proceeds), 2);
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

    -- Umschichten: Depot -m, Verrechnungskonto +m (derisk, append-only, stornierbar ueber source_tx_id).
    IF v_goal IS NOT NULL AND v_m > 0 THEN
        INSERT INTO finance.savings_goal_reserve_entries
            (savings_goal_id, account_id, delta_native, currency, value_date, source_tx_id, kind)
        VALUES (v_goal, v_depot, -v_m, v_sccy, v_date, v_sell, 'derisk'),
               (v_goal, v_settle, v_m, v_sccy, v_date, v_sell, 'derisk');
        SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
    END IF;

    -- Post-State (Trigger haben gefeuert): Verrechnungskonto-Saldo + Rest-Stuecke.
    SELECT balance INTO v_bal
    FROM finance.account_balances WHERE account_id = v_settle;
    SELECT shares INTO v_remain
    FROM finance.depot_holdings WHERE id = v_holding;

    RETURN jsonb_build_object('ok', true, 'sell_tx_id', v_sell,
        'settlement_balance', v_bal,
        'proceeds', v_proceeds,
        'remaining_shares', v_remain,
        'effective', (v_dates->'resolved') || jsonb_build_object('transaction_date', v_date, 'order_fee', v_fee))
        || CASE WHEN v_goal IS NOT NULL
                THEN jsonb_build_object('derisk_amount', v_m, 'current_amount', round(COALESCE(v_cur, 0), 2))
                ELSE '{}'::jsonb END;
END;
$$;
