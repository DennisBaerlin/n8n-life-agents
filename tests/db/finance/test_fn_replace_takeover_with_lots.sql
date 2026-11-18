-- ============================================================
-- test_fn_replace_takeover_with_lots -- Bestandsuebernahme -> echte Einzelkaeufe aus dem Broker-Export
--   Werte erfunden, Daten relativ zu core.fn_today(). Testbroker Cashkonto 1000 (Stichtag heute-20), Depot daran.
--   ALT: Uebernahme 10 Stueck @ 25 am heute-5. Export: Kauf 1 (heute-60) + Verkauf 1 (heute-50) = Bestand 0 (Reset),
--   Kauf 4 (heute-40, Kurswert 80, Gebuehr 1), Kauf 3 (heute-30, 66), Verkauf 2 (heute-28, FIFO aus dem ersten Lot),
--   Kauf 2 (heute-25, 50), Kauf 3 (heute-8, 90), Kauf 1 nach der Uebernahme (heute-2, bleibt unberuehrt).
--   -> 4 Lots = 2 + 3 + 2 + 3 = 10 Stueck; heute-8 liegt nach dem Stichtag -> echter Kauf (Cash -90), Rest cash-neutral.
--   Einstand (40.50 + 66 + 50 + 90) / 10 = 24.65. MIS: Uebernahme 5, Export 4 -> lots_mismatch, difference 1.
--   Zusammenspiel Monats-Check: vor dem Ersetzen steckt der Kauf heute-8 in der Uebernahme (covered_by_takeover), danach
--   ist er Stufe-0-"schon gebucht" -> nie doppelt.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.tr_hdr() RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]'::jsonb;
$$;
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
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSALT1',
                 'symbol', 'ALT', 'name', 'Alt ETF', 'shares', 10, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP alt: %', v_res; END IF;
    v_alt := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSMIS1',
                 'symbol', 'MIS', 'name', 'Mis ETF', 'shares', 5, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_mis := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSONE1',
                 'symbol', 'ONE', 'name', 'One ETF', 'shares', 2, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_one := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00LOTSDST1',
                 'symbol', 'DST', 'name', 'Dust ETF', 'shares', 0.00006, 'price_per_share', 200, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP dust: %', v_res; END IF;
    v_dst := (v_res->>'holding_id')::int;

    v_csv := jsonb_build_object('rows', jsonb_build_array(v_hdr) || jsonb_build_array(
        pg_temp.tr_row(T - 60, 'BUY',  'IE00LOTSALT1', '1.0000000000',  '-10.00', '-1.00', 'l-01'),
        pg_temp.tr_row(T - 50, 'SELL', 'IE00LOTSALT1', '-1.0000000000', '12.00',  '-1.00', 'l-02'),
        pg_temp.tr_row(T - 40, 'BUY',  'IE00LOTSALT1', '4.0000000000',  '-80.00', '-1.00', 'l-03'),
        pg_temp.tr_row(T - 30, 'BUY',  'IE00LOTSALT1', '3.0000000000',  '-66.00', '', 'l-04'),
        pg_temp.tr_row(T - 28, 'SELL', 'IE00LOTSALT1', '-2.0000000000', '44.00',  '-1.00', 'l-05'),
        pg_temp.tr_row(T - 25, 'BUY',  'IE00LOTSALT1', '2.0000000000',  '-50.00', '', 'l-06'),
        pg_temp.tr_row(T - 8,  'BUY',  'IE00LOTSALT1', '3.0000000000',  '-90.00', '', 'l-07'),
        pg_temp.tr_row(T - 2,  'BUY',  'IE00LOTSALT1', '1.0000000000',  '-31.00', '-1.00', 'l-08'),
        pg_temp.tr_row(T - 30, 'BUY',  'IE00LOTSMIS1', '4.0000000000',  '-40.00', '', 'l-09'),
        -- ONE: genau ein Kauf vor dem Stichtag -> die Ersetzung ist wieder ein Paar, darf aber nie erneut ersetzt werden
        pg_temp.tr_row(T - 30, 'BUY',  'IE00LOTSONE1', '2.0000000000',  '-24.00', '', 'l-10'),
        -- DST: FIFO-Rest 0.00001 @ 20 = 0.0002 EUR (unter 1 Cent) -> lots_not_bookable als Daten, kein Absturz
        pg_temp.tr_row(T - 40, 'BUY',  'IE00LOTSDST1', '1.0000000000',  '-20.00', '', 'l-11'),
        pg_temp.tr_row(T - 35, 'BUY',  'IE00LOTSDST1', '0.0000500000',  '-0.01', '', 'l-12'),
        pg_temp.tr_row(T - 30, 'SELL', 'IE00LOTSDST1', '-0.9999900000', '20.00', '', 'l-13')));
    v_p := jsonb_build_object('account_name', '__t_lots_tr__', 'table', v_csv);

    -- Monats-Check vor dem Ersetzen: Kauf heute-8 steckt in der Uebernahme -> nie gebucht
    v_prep := finance.fn_statement_prepare(v_p || jsonb_build_object('source', 'file', 'closing_balance', 878));
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

    -- Monats-Check danach: Kauf heute-8 schon gebucht (Stufe 0), nur der Kauf heute-2 wird gebucht, drift 0
    v_prep := finance.fn_statement_prepare(v_p || jsonb_build_object('source', 'file', 'closing_balance', 878));
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

-- L11 FIFO ueber mehrere Lots: Kauf 1 @ 10, 1 @ 20, 3 @ 30, Verkauf 3 -> uebrig 2 aus dem dritten Lot, Einstand 30
-- L12 Export, der die Position komplett wieder verkauft (Summe 0) -> lots_mismatch, nie stilles Ersetzen
-- L13 Stichtag = der spaetere von Eroeffnung und letztem Abgleich: ein Kauf dazwischen bewegt kein Geld
DO $$
DECLARE
    T DATE := core.fn_today();
    v_acc INT; v_dep INT; v_res JSONB;
BEGIN
    -- L11
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_fifo__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_fifo_dep__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'settlement_id', v_acc))->>'account_id')::int;
    PERFORM finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc, 'isin', 'IE00LOTSFIF1',
                 'symbol', 'FIF', 'name', 'Fif ETF', 'shares', 2, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, jsonb_build_object(
        'account_name', '__t_lots_fifo__', 'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.tr_hdr()) || jsonb_build_array(
            pg_temp.tr_row(T - 70, 'BUY',  'IE00LOTSFIF1', '1.0000000000',  '-10.00', '', 'f-01'),
            pg_temp.tr_row(T - 60, 'BUY',  'IE00LOTSFIF1', '1.0000000000',  '-20.00', '', 'f-02'),
            pg_temp.tr_row(T - 50, 'BUY',  'IE00LOTSFIF1', '3.0000000000',  '-90.00', '', 'f-03'),
            pg_temp.tr_row(T - 45, 'SELL', 'IE00LOTSFIF1', '-3.0000000000', '100.00', '', 'f-04')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->'replaced'->0->>'shares')::numeric IS DISTINCT FROM 2
       OR (v_res->'replaced'->0->>'avg_purchase_price')::numeric IS DISTINCT FROM 30 THEN
        RAISE EXCEPTION 'FAIL [L11 FIFO ueber drei Lots]: %', v_res; END IF;

    -- L12
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_zero__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_zero_dep__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'settlement_id', v_acc))->>'account_id')::int;
    PERFORM finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc, 'isin', 'IE00LOTSZER1',
                 'symbol', 'ZER', 'name', 'Zer ETF', 'shares', 2, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, jsonb_build_object(
        'account_name', '__t_lots_zero__', 'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.tr_hdr()) || jsonb_build_array(
            pg_temp.tr_row(T - 60, 'BUY',  'IE00LOTSZER1', '2.0000000000',  '-40.00', '', 'z-01'),
            pg_temp.tr_row(T - 50, 'SELL', 'IE00LOTSZER1', '-2.0000000000', '44.00', '', 'z-02')))));
    IF v_res::text NOT LIKE '%lots_mismatch%' OR jsonb_array_length(COALESCE(v_res->'replaced', '[]'::jsonb)) <> 0 THEN
        RAISE EXCEPTION 'FAIL [L12 komplett verkauft -> lots_mismatch]: %', v_res; END IF;

    -- L13
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_cut__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 10 WHERE id = v_acc;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_cut_dep__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'settlement_id', v_acc))->>'account_id')::int;
    PERFORM finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc, 'isin', 'IE00LOTSCUT1',
                 'symbol', 'CUT', 'name', 'Cut ETF', 'shares', 1, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, jsonb_build_object(
        'account_name', '__t_lots_cut__', 'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.tr_hdr()) || jsonb_build_array(
            pg_temp.tr_row(T - 15, 'BUY', 'IE00LOTSCUT1', '1.0000000000', '-12.00', '', 'c-01')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'settlement_change')::numeric IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FAIL [L13 Kauf vor dem letzten Abgleich bewegt kein Geld]: %', v_res; END IF;
    RAISE NOTICE 'PASS [L11-L13 FIFO ueber Lots, komplett verkauft, Stichtag = spaeterer Termin]';
END $$;

-- L14 Kauf am Uebernahme-Tag, den die Uebernahme noch nicht enthielt (Sparplan mittags, Bestand abends ohne ihn):
--   Uebernahme 2 Stueck am heute-10; Export Kauf 2 (heute-30, 50) + Kauf 0.5 (heute-10, 10). Vor dem Tag = 2 = Uebernahme
--   -> ersetzen mit beiden Lots, Bestand 2.5, same_day_shares 0.5, Stichtag (Abgleich heute-3) enthaelt den Kauf -> cash-neutral.
--   Gegenprobe: Kauf am Tag + Abweichung davor (Uebernahme 1.5) bleibt lots_mismatch.
DO $$
DECLARE
    T DATE := core.fn_today();
    v_acc INT; v_dep INT; v_h INT; v_res JSONB; v_p JSONB;
BEGIN
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_day__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 10)::text))->>'account_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 3 WHERE id = v_acc;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_day_dep__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'settlement_id', v_acc))->>'account_id')::int;
    v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc,
                 'isin', 'IE00LOTSDAY1', 'symbol', 'DAY', 'name', 'Day ETF', 'shares', 2, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 10)::text, 'existing_position', true))->>'holding_id')::int;
    PERFORM finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc,
                 'isin', 'IE00LOTSDAZ1', 'symbol', 'DAZ', 'name', 'Daz ETF', 'shares', 1.5, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 10)::text, 'existing_position', true));
    v_p := jsonb_build_object('account_name', '__t_lots_day__', 'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.tr_hdr()) || jsonb_build_array(
            pg_temp.tr_row(T - 30, 'BUY', 'IE00LOTSDAY1', '2.0000000000', '-50.00', '', 'd-01'),
            pg_temp.tr_row(T - 10, 'BUY', 'IE00LOTSDAY1', '0.5000000000', '-10.00', '', 'd-02'),
            pg_temp.tr_row(T - 30, 'BUY', 'IE00LOTSDAZ1', '2.0000000000', '-50.00', '', 'd-03'),
            pg_temp.tr_row(T - 10, 'BUY', 'IE00LOTSDAZ1', '0.5000000000', '-10.00', '', 'd-04'))));
    v_res := finance.fn_replace_takeover_with_lots(v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'replaced') <> 1
       OR (v_res->'replaced'->0->>'holding_id')::int <> v_h
       OR (v_res->'replaced'->0->>'lots_count')::int <> 2 OR (v_res->'replaced'->0->>'shares')::numeric <> 2.5
       OR (v_res->'replaced'->0->>'same_day_shares')::numeric IS DISTINCT FROM 0.5
       OR (v_res->'replaced'->0->>'take_date')::date IS DISTINCT FROM T - 10
       OR (v_res->'replaced'->0->>'avg_purchase_price')::numeric <> 24
       OR (v_res->>'settlement_change')::numeric <> 0 OR finance.fn_get_balance(v_acc) <> 1000
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'card_lines') l WHERE l->>'value' = 'finance.note.lots_takeover_day_added') THEN
        RAISE EXCEPTION 'FAIL [L14 Kauf am Uebernahme-Tag]: %', v_res; END IF;
    IF jsonb_array_length(v_res->'mismatched') <> 1 OR v_res->'mismatched'->0->>'name' <> 'Daz ETF'
       OR (v_res->'mismatched'->0->>'difference')::numeric <> -1 THEN
        RAISE EXCEPTION 'FAIL [L14b Abweichung vor dem Tag bleibt lots_mismatch]: %', v_res->'mismatched'; END IF;
    RAISE NOTICE 'PASS [L14 Kauf am Uebernahme-Tag kommt dazu, Abweichung davor bleibt]';
END $$;

-- L15 Verkauf am Uebernahme-Tag: Zeilen davor = Uebernahme (2), am Tag Kauf 1 + Verkauf 0.5 -> Export 2.5 > 2, aber der
--   Tag haelt nicht nur Kaeufe -> bleibt lots_mismatch (difference -0.5), nichts geaendert.
-- L16 Rundungsrest bei Kauf am Uebernahme-Tag: Zeilen davor 1 + 0.99999999 = Uebernahme 2 minus 1e-8 (Staub). Der Staub
--   gehoert auf ein Lot VOR dem Tag; der Kauf am Tag (nach dem Stichtag -> echter Kauf) behaelt die Export-Stueck exakt,
--   sonst findet Stufe 0 im Monats-Check ihn nicht (vergleicht Stueck exakt) und sperrt die Zeile als covered_by_takeover.
-- L17 Fremdwaehrungs-Zeile: die Datei traegt EUR + USD (Konto-Waechter nimmt sie an), eine Zeile der Position ist USD.
--   Ein USD-Kurswert als EUR-Einstand waere still falsch -> die Position wird nicht ersetzt (mismatched), Paar bleibt.
DO $$
DECLARE
    T DATE := core.fn_today();
    v_acc INT; v_dep INT; v_h INT; v_res JSONB; v_p JSONB; v_prep JSONB;
BEGIN
    -- L15
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_dsell__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 10)::text))->>'account_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 3 WHERE id = v_acc;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_dsell_dep__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'settlement_id', v_acc))->>'account_id')::int;
    v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc,
                 'isin', 'IE00LOTSDSL1', 'symbol', 'DSL', 'name', 'Dsl ETF', 'shares', 2, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 10)::text, 'existing_position', true))->>'holding_id')::int;
    v_res := finance.fn_replace_takeover_with_lots(jsonb_build_object('account_name', '__t_lots_dsell__',
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.tr_hdr()) || jsonb_build_array(
            pg_temp.tr_row(T - 30, 'BUY',  'IE00LOTSDSL1', '2.0000000000',  '-50.00', '', 'ds-01'),
            pg_temp.tr_row(T - 10, 'BUY',  'IE00LOTSDSL1', '1.0000000000',  '-20.00', '', 'ds-02'),
            pg_temp.tr_row(T - 10, 'SELL', 'IE00LOTSDSL1', '-0.5000000000', '11.00',  '', 'ds-03')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'replaced') <> 0
       OR jsonb_array_length(v_res->'mismatched') <> 1 OR v_res->'mismatched'->0->>'code' <> 'lots_mismatch'
       OR (v_res->'mismatched'->0->>'difference')::numeric <> -0.5
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_h) <> 1 THEN
        RAISE EXCEPTION 'FAIL [L15 Verkauf am Uebernahme-Tag bleibt lots_mismatch]: %', v_res; END IF;
    RAISE NOTICE 'PASS [L15 Verkauf am Uebernahme-Tag bleibt lots_mismatch]';

    -- L16 (Stichtag = Eroeffnung heute-20: Lots davor cash-neutral, der Kauf am Tag heute-10 ist ein echter Kauf -10)
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_ddust__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_ddust_dep__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'settlement_id', v_acc))->>'account_id')::int;
    v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc,
                 'isin', 'IE00LOTSDDU1', 'symbol', 'DDU', 'name', 'Ddu ETF', 'shares', 2, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 10)::text, 'existing_position', true))->>'holding_id')::int;
    v_p := jsonb_build_object('account_name', '__t_lots_ddust__',
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.tr_hdr()) || jsonb_build_array(
            pg_temp.tr_row(T - 30, 'BUY', 'IE00LOTSDDU1', '1.0000000000', '-25.00', '', 'dd-01'),
            pg_temp.tr_row(T - 25, 'BUY', 'IE00LOTSDDU1', '0.9999999900', '-25.00', '', 'dd-02'),
            pg_temp.tr_row(T - 10, 'BUY', 'IE00LOTSDDU1', '0.5000000000', '-10.00', '', 'dd-03'))));
    v_res := finance.fn_replace_takeover_with_lots(v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'replaced') <> 1
       OR (v_res->'replaced'->0->>'shares')::numeric <> 2.5 OR (v_res->>'settlement_change')::numeric <> -10 THEN
        RAISE EXCEPTION 'FAIL [L16a Ersetzen mit Staub + Kauf am Tag]: %', v_res; END IF;
    IF (SELECT shares FROM finance.transactions
        WHERE holding_id = v_h AND category::text = 'buy' AND transaction_date = T - 10) IS DISTINCT FROM 0.5 THEN
        RAISE EXCEPTION 'FAIL [L16b Kauf am Uebernahme-Tag traegt den Rundungsrest]: shares=%',
            (SELECT array_agg(shares ORDER BY transaction_date) FROM finance.transactions WHERE holding_id = v_h AND category::text = 'buy'); END IF;
    v_prep := finance.fn_statement_prepare(v_p || jsonb_build_object('source', 'file', 'closing_balance', 990));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'trades') <> 0
       OR jsonb_array_length(v_prep->'trades_blocked') <> 0
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'already_booked') b
                      WHERE (b->>'trade')::boolean AND (b->>'amount')::numeric = -10) THEN
        RAISE EXCEPTION 'FAIL [L16c Monats-Check: Kauf am Tag schon gebucht]: %', v_prep; END IF;
    RAISE NOTICE 'PASS [L16 Rundungsrest nie auf dem Kauf am Uebernahme-Tag]';

    -- L17
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_fx__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_lots_fx_dep__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'settlement_id', v_acc))->>'account_id')::int;
    v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_dep, 'settlement_id', v_acc,
                 'isin', 'IE00LOTSFXX1', 'symbol', 'FXX', 'name', 'Fxx ETF', 'shares', 2, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true))->>'holding_id')::int;
    v_res := finance.fn_replace_takeover_with_lots(jsonb_build_object('account_name', '__t_lots_fx__',
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.tr_hdr()) || jsonb_build_array(
            pg_temp.tr_row(T - 30, 'BUY', 'IE00LOTSFXX1', '1.0000000000', '-20.00', '', 'fx-01'),
            jsonb_build_array((T - 25)::text || 'T10:00:00Z', (T - 25)::text, 'DEFAULT', 'TRADING', 'BUY', 'FUND', 'IE00LOTSFXX1 ETF',
                              'IE00LOTSFXX1', '1.0000000000', '', '-30.00', '', '', 'USD', '', '', '', '', 'fx-02', '', '', '', '')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'replaced') r WHERE (r->>'holding_id')::int = v_h)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'mismatched') m WHERE (m->>'holding_id')::int = v_h)
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_h) <> 1 THEN
        RAISE EXCEPTION 'FAIL [L17 Fremdwaehrungs-Zeile ersetzt nie still]: %', v_res; END IF;
    RAISE NOTICE 'PASS [L17 Fremdwaehrungs-Zeile ersetzt nie still]';
END $$;
ROLLBACK;
