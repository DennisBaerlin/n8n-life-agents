-- ============================================================
-- test_fn_replace_takeover_with_lots -- Bestandsuebernahme -> echte Einzelkaeufe aus dem Broker-Export (Paket B)
--   Werte erfunden, Daten relativ zu core.fn_today(). TR-Cashkonto 1000 (Stichtag heute-20), Depot daran.
--   ALT: Uebernahme 10 Stueck @ 25 am heute-5. Export: Kauf 1 (heute-60) + Verkauf 1 (heute-50) = Bestand 0 (Reset),
--   Kauf 4 (heute-40, Kurswert 80, Gebuehr 1), Kauf 3 (heute-30, 66), Verkauf 2 (heute-28, FIFO aus dem ersten Lot),
--   Kauf 2 (heute-25, 50), Kauf 3 (heute-8, 90), Kauf 1 nach der Uebernahme (heute-2, bleibt unberuehrt).
--   -> 4 Lots = 2 + 3 + 2 + 3 = 10 Stueck; heute-8 liegt nach dem Stichtag -> echter Kauf (Cash -90), Rest cash-neutral.
--   Einstand (40.50 + 66 + 50 + 90) / 10 = 24.65. MIS: Uebernahme 5, Export 4 -> lots_mismatch, difference 1.
--   Zusammenspiel Monats-Check: vor dem Ersetzen steckt der Kauf heute-8 in der Uebernahme (covered_by_takeover), danach
--   ist er Stufe-0-"schon gebucht" -> nie doppelt.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.tr_row(p_d date, p_typ text, p_sym text, p_sh text, p_amt text, p_fee text, p_id text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text || 'T10:00:00Z', p_d::text, 'DEFAULT', 'TRADING', p_typ, 'FUND', p_sym || ' ETF', p_sym,
                             p_sh, '', p_amt, p_fee, '', 'EUR', '', '', '', '', p_id, '', '', '', '');
$$;
DO $$
DECLARE
    T       DATE := core.fn_today();
    v_hdr   JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_tr    INT;
    v_depot INT;
    v_alt   INT;
    v_mis   INT;
    v_res   JSONB;
    v_p     JSONB;
    v_csv   JSONB;
    v_grp   UUID;
    v_prep  JSONB;
    v_one   INT;
    v_dst   INT;
BEGIN
    v_res := finance.fn_create_account(jsonb_build_object('name', '__t_lots_tr__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text));
    v_tr := (v_res->>'account_id')::int;
    v_depot := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_depot__', 'account_type', 'stocks_depot',
                   'currency', 'EUR', 'settlement_id', v_tr))->>'account_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSALT1',
                 'symbol', 'ALT', 'name', 'Alt ETF', 'shares', 10, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP alt: %', v_res; END IF;
    v_alt := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSMIS1',
                 'symbol', 'MIS', 'name', 'Mis ETF', 'shares', 5, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_mis := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSONE1',
                 'symbol', 'ONE', 'name', 'One ETF', 'shares', 2, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_one := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSDST1',
                 'symbol', 'DST', 'name', 'Dust ETF', 'shares', 0.00006, 'price_per_share', 200, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP dust: %', v_res; END IF;
    v_dst := (v_res->>'holding_id')::int;

    v_csv := jsonb_build_object('header', v_hdr, 'rows', jsonb_build_array(
        pg_temp.tr_row(T - 60, 'BUY',  'IE00LOTSALT1', '1.0000000000',  '-10.00', '-1.00', 'l-01'),
        pg_temp.tr_row(T - 50, 'SELL', 'IE00LOTSALT1', '-1.0000000000', '12.00',  '-1.00', 'l-02'),
        pg_temp.tr_row(T - 40, 'BUY',  'IE00LOTSALT1', '4.0000000000',  '-80.00', '-1.00', 'l-03'),
        pg_temp.tr_row(T - 30, 'BUY',  'IE00LOTSALT1', '3.0000000000',  '-66.00', '', 'l-04'),
        pg_temp.tr_row(T - 28, 'SELL', 'IE00LOTSALT1', '-2.0000000000', '44.00',  '-1.00', 'l-05'),
        pg_temp.tr_row(T - 25, 'BUY',  'IE00LOTSALT1', '2.0000000000',  '-50.00', '', 'l-06'),
        pg_temp.tr_row(T - 8,  'BUY',  'IE00LOTSALT1', '3.0000000000',  '-90.00', '', 'l-07'),
        pg_temp.tr_row(T - 2,  'BUY',  'IE00LOTSALT1', '1.0000000000',  '-31.00', '-1.00', 'l-08'),
        pg_temp.tr_row(T - 30, 'BUY',  'IE00LOTSMIS1', '4.0000000000',  '-40.00', '', 'l-09'),
        -- ONE: genau EIN Kauf vor dem Stichtag -> die Ersetzung ist wieder ein Paar, darf aber nie erneut ersetzt werden
        pg_temp.tr_row(T - 30, 'BUY',  'IE00LOTSONE1', '2.0000000000',  '-24.00', '', 'l-10'),
        -- DST: FIFO-Rest 0.00001 @ 20 = 0.0002 EUR (unter 1 Cent) -> lots_not_bookable als Daten, kein Absturz
        pg_temp.tr_row(T - 40, 'BUY',  'IE00LOTSDST1', '1.0000000000',  '-20.00', '', 'l-11'),
        pg_temp.tr_row(T - 35, 'BUY',  'IE00LOTSDST1', '0.0000500000',  '-0.01', '', 'l-12'),
        pg_temp.tr_row(T - 30, 'SELL', 'IE00LOTSDST1', '-0.9999900000', '20.00', '', 'l-13')));
    v_p := jsonb_build_object('account_name', '__t_lots_tr__', 'csv', v_csv);

    -- Monats-Check VOR dem Ersetzen: Kauf heute-8 steckt in der Uebernahme -> nie gebucht
    v_prep := finance.fn_statement_prepare(v_p || jsonb_build_object('source', 'csv', 'closing_balance', 878));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'trades_blocked') b
                      WHERE b->>'reason' = 'covered_by_takeover' AND (b->>'amount')::numeric = -90)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'trades') x WHERE (x->>'amount')::numeric = -90) THEN
        RAISE EXCEPTION 'FAIL [L1 vorher covered_by_takeover]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [L1 Monats-Check vor dem Ersetzen]';

    -- Probelauf = Zahlen des echten Writes, nichts bleibt
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'settlement_change')::numeric <> -90
       OR jsonb_array_length(v_res->'card_lines') = 0
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_alt) <> 1 THEN
        RAISE EXCEPTION 'FAIL [L2 Probelauf]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [L2 Probelauf]';

    -- Plan/Apply: ein anderer fingerprint als der der Karte -> stale_preview, nichts geschrieben
    v_prep := finance.fn_replace_takeover_with_lots(v_p || '{"fingerprint":"00000000000000000000000000000000"}'::jsonb);
    IF v_prep->>'code' IS DISTINCT FROM 'stale_preview' OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_alt) <> 1 THEN
        RAISE EXCEPTION 'FAIL [L2b stale_preview]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [L2b fingerprint]';

    v_res := finance.fn_replace_takeover_with_lots(v_p || jsonb_build_object('fingerprint', v_res->>'fingerprint'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'replaced') <> 2
       OR v_res->'replaced'->1->>'name' <> 'One ETF' THEN
        RAISE EXCEPTION 'FAIL [L3 ok]: %', v_res;
    END IF;
    IF (v_res->'replaced'->0->>'lots_count')::int <> 4 OR (v_res->'replaced'->0->>'cash_lots_count')::int <> 1
       OR (v_res->'replaced'->0->>'shares')::numeric <> 10 OR (v_res->'replaced'->0->>'avg_purchase_price')::numeric <> 24.65
       OR (v_res->'replaced'->0->>'avg_before')::numeric <> 25 THEN
        RAISE EXCEPTION 'FAIL [L4 Lots + Einstand]: %', v_res->'replaced';
    END IF;
    IF (v_res->>'settlement_change')::numeric <> -90 OR (v_res->>'settlement_balance')::numeric <> 910
       OR finance.fn_get_balance(v_tr) <> 910 THEN
        RAISE EXCEPTION 'FAIL [L5 Cash-Wirkung nur fuer den Kauf nach dem Stichtag]: %', v_res;
    END IF;
    IF jsonb_array_length(v_res->'mismatched') <> 2 OR v_res->'mismatched'->0->>'code' <> 'lots_mismatch'
       OR v_res->'mismatched'->1->>'code' <> 'lots_not_bookable' OR (v_res->'mismatched'->1->>'holding_id')::int <> v_dst
       OR (SELECT count(*) FROM finance.transactions t WHERE t.holding_id = v_dst) <> 1
       OR (v_res->'mismatched'->0->>'difference')::numeric <> 1 OR (v_res->'mismatched'->0->>'export_shares')::numeric <> 4
       OR (SELECT count(*) FROM finance.transactions t WHERE t.holding_id = v_mis) <> 1 THEN
        RAISE EXCEPTION 'FAIL [L6 Abweichung, MIS unveraendert]: %', v_res->'mismatched';
    END IF;
    SELECT group_id INTO v_grp FROM finance.transactions WHERE holding_id = v_alt LIMIT 1;
    IF (SELECT count(*) FROM finance.transactions WHERE group_id = v_grp AND category::text = 'buy') <> 4
       OR (SELECT count(*) FROM finance.transactions WHERE group_id = v_grp AND category::text = 'position_takeover') <> 3
       OR (SELECT count(DISTINCT group_id) FROM finance.transactions WHERE holding_id = v_alt) <> 1
       OR (SELECT count(*) FROM finance.transaction_audit WHERE reason = 'replaced_by_lots' AND replaced_by_group = v_grp) <> 2 THEN
        RAISE EXCEPTION 'FAIL [L7 eine group_id, Audit]';
    END IF;
    RAISE NOTICE 'PASS [L3-L7 Ersetzen]';

    -- erneut: kein Uebernahme-Paar mehr mit genau einem Kauf -> nichts ersetzt (ALT), MIS bleibt Abweichung
    v_res := finance.fn_replace_takeover_with_lots(v_p);
    IF jsonb_array_length(v_res->'replaced') <> 0 OR (v_res->>'settlement_change')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [L8 idempotent]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [L8 erneut]';

    -- Monats-Check DANACH: Kauf heute-8 schon gebucht (Stufe 0), nur der Kauf heute-2 wird gebucht, drift 0
    v_prep := finance.fn_statement_prepare(v_p || jsonb_build_object('source', 'csv', 'closing_balance', 878));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR (v_prep->>'drift')::numeric <> 0 OR (v_prep->>'lump')::numeric <> 0
       OR jsonb_array_length(v_prep->'trades') <> 1 OR (v_prep->'trades'->0->>'amount')::numeric <> -32
       OR jsonb_array_length(v_prep->'trades_blocked') <> 0
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'already_booked') b
                      WHERE (b->>'trade')::boolean AND (b->>'amount')::numeric = -90) THEN
        RAISE EXCEPTION 'FAIL [L9 Monats-Check danach]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [L9 Monats-Check danach, nie doppelt]';

    -- Void des Ersatzes entfernt die ganze neue Gruppe (ein Write = ein Void)
    v_res := finance.fn_void_transaction(jsonb_build_object('transaction_id',
                 (SELECT min(id) FROM finance.transactions WHERE group_id = v_grp)));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'deleted_count')::int <> 7 THEN
        RAISE EXCEPTION 'FAIL [L10 Void der Gruppe]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [L10 Void]';
END $$;
ROLLBACK;
