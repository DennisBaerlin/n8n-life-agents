-- ============================================================
-- fn_book_savings_plan_execution (ATOMIC WRITE)
--   Bucht eine Sparplan-Ausfuehrung: liest das offene Vorkommen aus fn_savings_plan_next_execution (dieselbe fn
--   speist die HITL-Karte -> Karte = Buchung; ueber die ganze Vorgaenger-Kette, Audit Paket 2 Punkt 3: eine noch
--   anstehende Ausfuehrung zu alten Konditionen bucht auf die ALTE rp mit deren Betrag),
--   setzt transaction_date=due_date + recurring_payment_id (dieses Ketten-Glied) auf die Kauf-Transaktion ->
--   Vorkommen verschwindet automatisch aus der offenen Liste (kein Write an fn_recurring_due_open).
--   Ruft fn_book_stock_buy intern auf (Depot, Settlement, Holding/Trigger werden daraus bedient).
--   Eingabe jsonb: savings_plan_name, shares, price_per_share, order_fee (opt, default 0).
--   ODER (Monats-Check WP-A, Kontoauszug-Pfad): recurring_payment_id + due_date (das konkrete Vorkommen, das der
--   Auszug zugeordnet hat) + transaction_date (Ist-Datum, Default due_date) statt savings_plan_name -> kein
--   "fruehestes offenes Vorkommen" (das koennte ein aelteres, noch offenes treffen); Plan ueber den Kettenkopf.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, holding_id, buy_tx_id, due_date, total_cost,
--   plan_amount, variance}. Korrigierbar (Plan nicht aktiv, kein offenes Vorkommen, shares<=0,
--   price<=0) -> {ok:false, reason} OHNE Write.
--   WS-6: die null_tag-Note aus fn_book_stock_buy wird NICHT durchgereicht (diese fn baut ihren eigenen
--   Return; der Sparplan-Cron surfaced keine Envelope-Notes — der Plan-asset_class vererbt sich ohnehin
--   an die Holding, sodass eine getaggte Plan-Ausfuehrung gar keine Note erzeugte).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_savings_plan_execution(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_plan_name TEXT    := p->>'savings_plan_name';
    v_shares    NUMERIC := (p->>'shares')::numeric;
    v_price     NUMERIC := (p->>'price_per_share')::numeric;
    v_fee       NUMERIC := COALESCE(NULLIF(p->>'order_fee', '')::numeric, 0);
    v_plan      finance.savings_plans%ROWTYPE;
    v_next      JSONB;
    v_plan_amt  NUMERIC;
    v_due_date  DATE;
    v_total     NUMERIC;
    v_variance  NUMERIC;
    v_buy_json  JSONB;
    v_buy_result JSONB;
    v_rp_in     INT     := NULLIF(p->>'recurring_payment_id', '')::int;
    v_tx_date   DATE;
    v_dates     JSONB;
BEGIN
    -- relative Ist-Datumsangabe ("yesterday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}.
    -- due_date kommt aus dem DB-Lookup (Vorkommen-Identitaet), nie vom LLM -> nicht aufgeloest.
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    -- Input-Pruefungen
    IF v_shares IS NULL OR v_shares <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Shares must be a positive number, got ' || COALESCE(v_shares::text, 'null') || '.');
    END IF;
    IF v_price IS NULL OR v_price <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Price per share must be a positive number, got ' || COALESCE(v_price::text, 'null') || '.');
    END IF;

    -- Plan aufloesen + offenes Vorkommen ueber die Kette (eine Quelle mit der HITL-Karte; {ok:false} durchreichen:
    -- nicht gefunden, mehrdeutig, nicht aktiv, kein offenes Vorkommen).
    IF v_rp_in IS NOT NULL THEN
        -- Kontoauszug-Pfad: das zugeordnete Vorkommen direkt (Idempotenz/Sperre erledigt fn_book_stock_buy).
        SELECT * INTO v_plan FROM finance.savings_plans
        WHERE recurring_payment_id = finance.fn_recurring_lineage_head(v_rp_in);
        IF NOT FOUND THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Recurring payment ' || v_rp_in || ' does not belong to a savings plan.');
        END IF;
        v_due_date := (p->>'due_date')::date;
        SELECT abs(amount) INTO v_plan_amt FROM finance.recurring_payments WHERE id = v_rp_in;
        v_next := jsonb_build_object('settlement_account_id',
                    (SELECT account_id FROM finance.recurring_payments WHERE id = v_rp_in),
                    'recurring_payment_id', v_rp_in);
    ELSE
        v_next := finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name', v_plan_name));
        IF (v_next->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_next;
        END IF;
        SELECT * INTO v_plan FROM finance.savings_plans WHERE id = (v_next->>'savings_plan_id')::int;
        v_due_date := (v_next->>'due_date')::date;
        v_plan_amt := (v_next->>'plan_amount')::numeric;
    END IF;
    v_tx_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, v_due_date);

    -- Abweichungs-Berechnung (informativ; kein harter Block — Gate ist Safeguard), gegen den Betrag GENAU der
    -- rp, deren Vorkommen gebucht wird.
    v_total    := v_shares * v_price + v_fee;
    v_variance := ROUND(ABS(v_total - v_plan_amt) / NULLIF(v_plan_amt, 0) * 100, 2);

    -- fn_book_stock_buy aufrufen mit recurring_payment_id + due_date. WS-6: die Anlageklasse des Plans wird
    -- vererbt -> eine vom Sparplan ANGELEGTE Position traegt den Tag, nie leer (fn_book_stock_buy taggt nur beim
    -- Anlegen; NULL = Plan ungetaggt -> wie zuvor untagged, periodische null_tag-Meldung faengt es).
    v_buy_json := jsonb_build_object(
        'depot_id',              v_plan.depot_id,
        'settlement_id',         (v_next->>'settlement_account_id')::int,
        'isin',                  v_plan.isin,
        'symbol',                v_plan.symbol,
        'name',                  v_plan.security_name,
        'shares',                v_shares,
        'price_per_share',       v_price,
        'order_fee',             v_fee,
        'transaction_date',      v_tx_date,
        'due_date',              v_due_date,
        'asset_class',           v_plan.asset_class,
        'recurring_payment_id',  (v_next->>'recurring_payment_id')::int
    );

    SELECT finance.fn_book_stock_buy(v_buy_json) INTO v_buy_result;

    IF NOT (v_buy_result->>'ok')::boolean THEN
        RETURN v_buy_result;   -- Depot-Typ-Mismatch o.ä. durchreichen
    END IF;

    RETURN jsonb_build_object(
        'ok',           true,
        'holding_id',   (v_buy_result->>'holding_id')::int,
        'buy_tx_id',    (v_buy_result->>'buy_tx_id')::int,
        'due_date',     v_due_date,
        'total_cost',   v_total,
        'plan_amount',  v_plan_amt,
        'variance',     v_variance,
        'effective',    v_dates->'resolved'
    );
END;
$$;
