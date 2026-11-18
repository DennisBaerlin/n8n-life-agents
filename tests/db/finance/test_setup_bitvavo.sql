-- ============================================================
-- test_setup_bitvavo -- Ersteinrichtung aus einem Bitvavo-Export (fn_setup_*, fn_setup_effective_rows, fn_setup_positions)
--   Erfundene Zeilen gleicher Form wie ein Bitvavo-Transaktions-Export: Einzahlung, Kaeufe (Gebuehr im bezahlten Betrag),
--   Staking-Ertraege vor und nach einem Verkauf, eine Muenze nur aus Ertraegen. Euro-Rest 41.65.
--   Erwartung: Bestaende = Kaeufe - Verkaeufe + Ertraege; Ertraege bleiben eigene reward-Buchungen (kein Uebernahme-Lot
--   mit Kosten 0), die Muenze nur aus Ertraegen hat Einstand 0; die Einrichtung bewegt kein Geld.
--   Erneut derselbe Export im Monats-Check: nichts doppelt (already_covered bzw. keine trades).
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.bv(p_d date, p_typ text, p_cur text, p_amt text, p_px text, p_paid text, p_fee text, p_status text, p_id text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array('Europe/Amsterdam', p_d::text, '10:00:00', p_typ, p_cur, p_amt,
                             CASE WHEN p_px = '' THEN '' ELSE 'EUR' END, p_px,
                             CASE WHEN p_paid = '' THEN '' ELSE 'EUR' END, p_paid,
                             CASE WHEN p_fee = '' THEN '' ELSE 'EUR' END, p_fee, p_status, p_id, '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["Timezone","Date","Time","Type","Currency","Amount","Quote Currency","Quote Price","Received / Paid Currency","Received / Paid Amount","Fee currency","Fee amount","Status","Transaction ID","Address"]';
    v_tbl  JSONB;
    v_chat TEXT := '990000222';
    v_r    JSONB;
    v_acct INT;
    v_dep  INT;
    v_bal  NUMERIC;
BEGIN
    v_tbl := jsonb_build_object('rows', jsonb_build_array(v_hdr,
        pg_temp.bv(T-60, 'deposit',       'EUR',  '100.00',      '',         '',       '0.00', 'Completed',   'su-01'),
        pg_temp.bv(T-50, 'buy',           'BTC',  '0.00100000',  '60000.00', '-60.15', '0.15', 'Completed',   'su-02'),
        pg_temp.bv(T-45, 'staking',       'BTC',  '0.00001000',  '',         '',       '',     'Distributed', 'su-03'),
        pg_temp.bv(T-40, 'buy',           'ETH',  '0.01000000',  '3000.00',  '-30.10', '0.10', 'Completed',   'su-04'),
        pg_temp.bv(T-35, 'staking',       'ETH',  '0.00020000',  '',         '',       '',     'Distributed', 'su-05'),
        pg_temp.bv(T-30, 'fixed_staking', 'ETH',  '0.00030000',  '',         '',       '',     'Completed',   'su-06'),
        pg_temp.bv(T-20, 'sell',          'BTC',  '-0.00050000', '63960.00', '31.90',  '0.08', 'Completed',   'su-07'),
        pg_temp.bv(T-10, 'staking',       'SOLX', '0.50000000',  '',         '',       '',     'Distributed', 'su-08')));

    -- ---------- Start ohne Konto: Bitvavo erkannt, Euro-Konto mit Rest 41.65 ----------
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', v_chat, 'file_id', 'b1', 'table', v_tbl));
    IF (v_r->>'setup')::boolean IS DISTINCT FROM true OR v_r->>'phase' <> 'cash_account' OR v_r->'ask'->>'key' <> 'current_balance' THEN
        RAISE EXCEPTION 'FAIL [B1 Start]: %', v_r; END IF;
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl, 'question_key', 'current_balance', 'answer', '41,65'));
    v_acct := (finance.fn_create_account(v_r->'card'->'params')->>'account_id')::int;
    IF v_acct IS NULL OR finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'bitvavo_v1' THEN
        RAISE EXCEPTION 'FAIL [B2 Konto Bitvavo]: %', v_r; END IF;

    -- ---------- Krypto-Depot ----------
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl));
    IF v_r->>'phase' <> 'crypto_depot' THEN RAISE EXCEPTION 'FAIL [B3 Krypto-Depot]: %', v_r; END IF;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_bvsu_dep__', 'account_type', 'crypto_depot',
                 'currency', 'EUR', 'settlement_id', v_acct))->>'account_id')::int;

    -- ---------- Positionen der Reihe nach einstellen, bis die Einrichtung schliesst ----------
    v_bal := finance.fn_get_balance(v_acct);
    FOR i IN 1..6 LOOP
        v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl));
        EXIT WHEN (v_r->>'closed')::boolean;
        IF v_r->>'phase' = 'positions' THEN
            v_r := finance.fn_import_bundle(jsonb_build_object('batch_id', v_r->>'batch_id'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [B4 Commit]: %', v_r; END IF;
        ELSIF v_r->>'phase' = 'open_items' THEN
            RAISE EXCEPTION 'FAIL [B4b kein offener Punkt erwartet]: %', v_r;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM finance.setup_session WHERE chat_id = v_chat) THEN RAISE EXCEPTION 'FAIL [B5 Abschluss]: %', v_r; END IF;

    -- ---------- Bestaende inkl. Ertraege, kein Geld bewegt ----------
    IF (SELECT string_agg(symbol || ':' || shares::text, ',' ORDER BY symbol) FROM finance.depot_holdings WHERE account_id = v_dep)
       IS DISTINCT FROM 'BTC:0.00051000,ETH:0.01050000,SOLX:0.50000000' THEN
        RAISE EXCEPTION 'FAIL [B6 Bestaende]: %', (SELECT jsonb_agg(to_jsonb(h)) FROM finance.depot_holdings h WHERE account_id = v_dep); END IF;
    IF finance.fn_get_balance(v_acct) <> v_bal OR v_bal <> 41.65 THEN
        RAISE EXCEPTION 'FAIL [B7 Saldo unveraendert]: % / %', v_bal, finance.fn_get_balance(v_acct); END IF;
    IF (SELECT count(*) FROM finance.transactions t JOIN finance.depot_holdings h ON h.id = t.holding_id
        WHERE h.account_id = v_dep AND t.category::text = 'reward' AND t.amount = 0) <> 4
       OR (SELECT sum(t.shares) FROM finance.transactions t JOIN finance.depot_holdings h ON h.id = t.holding_id
           WHERE h.symbol = 'ETH' AND h.account_id = v_dep AND t.category::text = 'reward') <> 0.0005 THEN
        RAISE EXCEPTION 'FAIL [B8 Ertraege als eigene reward-Buchungen]'; END IF;
    IF (SELECT average_purchase_price FROM finance.depot_holdings WHERE account_id = v_dep AND symbol = 'SOLX') IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FAIL [B9 nur Ertraege -> Einstand 0]'; END IF;
    RAISE NOTICE 'PASS [B1-B9 Ersteinrichtung mit Ertraegen]';

    -- ---------- derselbe Export im Monats-Check: nichts doppelt ----------
    v_r := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'table', v_tbl, 'closing_balance', 41.65));
    IF v_r->>'code' IS DISTINCT FROM 'already_covered'
       AND ((v_r->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(COALESCE(v_r->'trades', '[]'::jsonb)) <> 0) THEN
        RAISE EXCEPTION 'FAIL [B10 Re-Import ohne Doppelung]: %', v_r; END IF;
    RAISE NOTICE 'PASS [B10 Re-Import]';
END $$;

-- Staging-Art reward: im Aktiendepot nur mit ISIN (wie stock_buy), sonst entstuende eine Position ohne ISIN
DO $$
DECLARE
    v_set INT;
    v_r   JSONB;
BEGIN
    v_set := (finance.fn_create_account('{"name":"__t_bvsu_sd_set__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_bvsu_sd__', 'account_type', 'stocks_depot',
                'currency', 'EUR', 'settlement_id', v_set));
    v_r := finance.fn_import_stage(jsonb_build_object('source', 'csv', 'rows', jsonb_build_array(
               jsonb_build_object('entity_type', 'reward', 'depot', '__t_bvsu_sd__', 'symbol', 'VWXX', 'shares', 1,
                                  'transaction_date', (core.fn_today() - 5)::text))));
    IF (v_r->>'invalid')::int IS DISTINCT FROM 1 OR (v_r->'errors')::text NOT LIKE '%isin is required%' THEN
        RAISE EXCEPTION 'FAIL [B11 reward im Aktiendepot ohne ISIN]: %', v_r; END IF;
    RAISE NOTICE 'PASS [B11 reward im Aktiendepot nur mit ISIN]';
END $$;
ROLLBACK;
