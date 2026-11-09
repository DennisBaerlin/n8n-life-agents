-- ============================================================
-- test_fn_setup_flow -- gefuehrte Ersteinrichtung aus einer Export-Datei (fn_setup_*, fn_import_positions_from_export)
--   Erfundene Zeilen gleicher Form wie ein Trade-Republic-Export: Kauf, Teilverkauf, Fusion mit Steuer-Zeile, Abspaltung, Einbuchung,
--   Kauf ohne Betrag, 10 Nachkommastellen, Fremdwaehrung. Sollwerte stehen im Test.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.tr_row(p_d date, p_cat text, p_typ text, p_cls text, p_name text, p_sym text, p_sh text,
                               p_px text, p_amt text, p_fee text, p_id text, p_ccy text DEFAULT 'EUR')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text || 'T10:00:00Z', p_d::text, 'DEFAULT', p_cat, p_typ, p_cls, p_name, p_sym, p_sh,
                             p_px, p_amt, p_fee, '', p_ccy, '', '', '', '', p_id, '', '', '', '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_tbl  JSONB;
    v_chat TEXT := '990000111';
    v_r    JSONB;
    v_acct INT;
    v_dep  INT;
    v_pos  JSONB;
    v_x    JSONB;
    v_h    finance.depot_holdings%ROWTYPE;
    v_bal  NUMERIC;
BEGIN
    v_tbl := jsonb_build_object('rows', jsonb_build_array(v_hdr,
        pg_temp.tr_row(T-400,'CASH','CUSTOMER_INPAYMENT','','','','','','5000.00','','a0'),
        -- Normalfall mit Teilverkauf und mehr Stellen als gespeichert
        pg_temp.tr_row(T-300,'TRADING','BUY','FUND','Birken ETF','IE00TESTAAA1','2.0000000012','50.00','-100.00','-1.00','a1'),
        pg_temp.tr_row(T-200,'TRADING','BUY','FUND','Birken ETF','IE00TESTAAA1','2.0000000000','60.00','-120.00','-1.00','a2'),
        pg_temp.tr_row(T-100,'TRADING','SELL','FUND','Birken ETF','IE00TESTAAA1','-1.0000000000','70.00','70.00','-1.00','a3'),
        -- Fusion alt -> neu, neue ISIN schon im Bestand, Steuer-Zeile danach
        pg_temp.tr_row(T-260,'TRADING','BUY','FUND','Alt Fonds','LU00TESTOLD1','10.0000000000','10.00','-100.00','','b1'),
        pg_temp.tr_row(T-255,'TRADING','BUY','FUND','Neu Fonds','IE00TESTNEW1','1.0000000000','30.00','-30.00','','b2'),
        pg_temp.tr_row(T-150,'CORPORATE_ACTION','MERGER','FUND','Alt Fonds','LU00TESTOLD1','-10.0000000000','','','','b3',''),
        pg_temp.tr_row(T-150,'CORPORATE_ACTION','MERGER','FUND','Neu Fonds','IE00TESTNEW1','3.0000000000','','','','b4',''),
        pg_temp.tr_row(T-146,'CASH','MERGER','FUND','Alt Fonds','LU00TESTOLD1','','','0.00','','b5'),
        -- Abspaltung, Einbuchung, Kauf ohne Betrag
        pg_temp.tr_row(T-120,'CORPORATE_ACTION','SPIN_OFF','STOCK','Teil AG','DE00TESTSPIN','4.0000000000','','','','c1',''),
        pg_temp.tr_row(T-110,'DELIVERY','FREE_RECEIPT','STOCK','Gratis AG','DE00TESTFREE','2.0000000000','','','','c2',''),
        pg_temp.tr_row(T-90,'TRADING','BUY','STOCK','Zeichnung AG','US00TESTIPO1','1.5000000000','20.00','','','c3'),
        -- Verkauf ohne Kauf, Fremdwaehrung
        pg_temp.tr_row(T-80,'TRADING','SELL','STOCK','Unvoll AG','DE00TESTSOLD','-1.0000000000','10.00','10.00','','d1'),
        pg_temp.tr_row(T-70,'TRADING','BUY','STOCK','Dollar Inc','US00TESTUSD1','1.0000000000','90.00','-90.00','','d2','USD'),
        pg_temp.tr_row(T,'CASH','CARD_TRANSACTION','','','','','','-5.00','','z1')));

    -- ---------- Start ohne Konto ----------
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', v_chat, 'file_id', 'f1', 'table', v_tbl));
    IF (v_r->>'setup')::boolean IS DISTINCT FROM true OR v_r->>'phase' <> 'cash_account' OR v_r->'ask'->>'key' <> 'current_balance'
       OR v_r->>'interest_source' <> 'web' THEN RAISE EXCEPTION 'FAIL [S1 Start]: %', v_r; END IF;
    -- gleiche Datei: kein zweiter Lauf
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', v_chat, 'file_id', 'f2', 'table', v_tbl));
    IF (SELECT count(*) FROM finance.setup_session WHERE chat_id = v_chat) <> 1
       OR (SELECT file_id FROM finance.setup_session WHERE chat_id = v_chat) <> 'f2' THEN RAISE EXCEPTION 'FAIL [S2 Wiederholung]'; END IF;

    -- ---------- Saldo merken, Konto-Karte ----------
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl, 'question_key', 'current_balance', 'answer', '1.234,56'));
    IF v_r->>'phase' <> 'cash_account' OR (v_r->'card'->'params'->>'opening_balance')::numeric <> 1234.56 THEN RAISE EXCEPTION 'FAIL [S3 Saldo]: %', v_r; END IF;
    v_acct := (finance.fn_create_account(v_r->'card'->'params')->>'account_id')::int;
    IF v_acct IS NULL THEN RAISE EXCEPTION 'FAIL [S3b Konto]'; END IF;

    -- ---------- Monats-Check bleibt gesperrt: Datei bringt nichts Neues, fragt aber nie nach dem Saldo ----------
    v_r := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'table', v_tbl));
    IF v_r->>'code' <> 'already_covered' THEN RAISE EXCEPTION 'FAIL [S4 already_covered vor Saldo]: %', v_r; END IF;

    -- ---------- Depot ----------
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl));
    IF v_r->>'phase' <> 'depot' OR v_r->'card'->'params'->>'settlement_account_name' IS NULL THEN RAISE EXCEPTION 'FAIL [S5 Depot]: %', v_r; END IF;
    IF (SELECT cash_account_id FROM finance.setup_session WHERE chat_id = v_chat) <> v_acct THEN RAISE EXCEPTION 'FAIL [S5b Bindung]'; END IF;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_su_dep__', 'account_type', 'stocks_depot', 'currency', 'EUR', 'settlement_id', v_acct))->>'account_id')::int;

    -- ---------- Positionen ----------
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl));
    IF v_r->>'phase' <> 'positions' OR (v_r->>'positions')::int <> 3 OR (v_r->>'invalid')::int <> 0 THEN RAISE EXCEPTION 'FAIL [S6 Positionen]: %', v_r; END IF;

    v_pos := finance.fn_setup_positions(
        (finance.fn_bank_export_normalize(v_tbl))->'rows', '{}'::jsonb, v_acct, T);
    -- FIFO: vom ersten Kauf (2,00000000 gerundet) wird 1 verkauft, Rest 1 zu 50 + halbe Gebuehr; zweiter Kauf voll
    SELECT p INTO v_x FROM jsonb_array_elements(v_pos->'positions') p WHERE p->>'isin' = 'IE00TESTAAA1';
    IF (v_x->>'shares')::numeric <> 3 OR (v_x->>'cost')::numeric <> 171.50 OR jsonb_array_length(v_x->'lots') <> 2 THEN RAISE EXCEPTION 'FAIL [P1 FIFO]: %', v_x; END IF;
    -- Fusion: 10 alt -> 3 neu, Einstand 100 bleibt, plus vorhandener Kauf
    SELECT p INTO v_x FROM jsonb_array_elements(v_pos->'positions') p WHERE p->>'isin' = 'IE00TESTNEW1';
    IF (v_x->>'shares')::numeric <> 4 OR (v_x->>'cost')::numeric <> 130 OR NOT (v_x->'hints') ? 'merger' THEN RAISE EXCEPTION 'FAIL [P2 Fusion]: %', v_x; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_pos->'positions') p WHERE p->>'isin' = 'LU00TESTOLD1') THEN RAISE EXCEPTION 'FAIL [P3 alt geschlossen]'; END IF;
    -- Kauf ohne Betrag = Stueck x Kurs mit Hinweis
    SELECT p INTO v_x FROM jsonb_array_elements(v_pos->'positions') p WHERE p->>'isin' = 'US00TESTIPO1';
    IF (v_x->>'cost')::numeric <> 30 OR NOT (v_x->'hints') ? 'buy_without_amount' THEN RAISE EXCEPTION 'FAIL [P4 ohne Betrag]: %', v_x; END IF;
    -- offene Punkte blockieren nichts
    IF (SELECT count(*) FROM jsonb_array_elements(v_pos->'open_items') o WHERE o->>'type' IN ('spin_off','free_receipt','position_incomplete','mixed_currency')) <> 4
       THEN RAISE EXCEPTION 'FAIL [P5 offene Punkte]: %', v_pos->'open_items'; END IF;
    -- Karte: je Position eine Zeile
    v_x := finance.fn_import_card_rows((SELECT batch_id FROM finance.setup_session WHERE chat_id = v_chat));
    IF jsonb_array_length(v_x) <> 3 THEN RAISE EXCEPTION 'FAIL [P6 Karte]: %', v_x; END IF;
    SELECT p INTO v_x FROM jsonb_array_elements(v_x) p WHERE p->'p'->>'isin' = 'IE00TESTAAA1';
    IF (v_x->'x'->>'lots_count')::int <> 2 OR (v_x->'p'->>'shares')::numeric <> 3 THEN RAISE EXCEPTION 'FAIL [P7 Karte Summe]: %', v_x; END IF;

    -- ---------- Commit: geldneutral, Herkunft gestempelt ----------
    v_bal := finance.fn_get_balance(v_acct);
    v_r := finance.fn_import_bundle(jsonb_build_object('batch_id', (SELECT batch_id FROM finance.setup_session WHERE chat_id = v_chat)));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [C1 Commit]: %', v_r; END IF;
    IF finance.fn_get_balance(v_acct) <> v_bal THEN RAISE EXCEPTION 'FAIL [C2 Saldo]'; END IF;
    SELECT * INTO v_h FROM finance.depot_holdings WHERE account_id = v_dep AND isin = 'IE00TESTAAA1';
    IF v_h.shares <> 3 THEN RAISE EXCEPTION 'FAIL [C3 Bestand]: %', v_h.shares; END IF;
    IF (SELECT count(*) FROM finance.transactions t WHERE t.holding_id = v_h.id AND t.cost_origin = 'export') <> 2 THEN RAISE EXCEPTION 'FAIL [C4 cost_origin]'; END IF;

    -- ---------- Offene Punkte der Reihe nach ----------
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl, 'historic_price', 25));
    IF v_r->>'phase' <> 'open_items' OR (v_r->'ask'->>'suggested_amount')::numeric <> 100 OR v_r->'ask'->>'type' <> 'spin_off' THEN RAISE EXCEPTION 'FAIL [O1 Vorschlag]: %', v_r; END IF;
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl, 'historic_price', 25, 'question_key', v_r->'ask'->>'key', 'answer', 'accept'));
    -- beantwortet: naechster Aufruf stellt genau diese Position ein
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl));
    IF v_r->>'phase' <> 'positions' OR (v_r->>'positions')::int <> 1 THEN RAISE EXCEPTION 'FAIL [O2 zweite Runde]: %', v_r; END IF;
    v_r := finance.fn_import_bundle(jsonb_build_object('batch_id', v_r->>'batch_id'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [O3 Commit]: %', v_r; END IF;
    IF (SELECT t.cost_origin FROM finance.transactions t JOIN finance.depot_holdings h ON h.id = t.holding_id
        WHERE h.isin = 'DE00TESTSPIN' AND t.category = 'buy') <> 'estimated' THEN RAISE EXCEPTION 'FAIL [O4 geschaetzt]'; END IF;

    -- Einstand 0 gibt es nicht; alles andere weglassen
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl));
    v_x := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl, 'question_key', v_r->'ask'->>'key', 'amount', '0'));
    IF (v_x->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [O5 Einstand 0]: %', v_x; END IF;
    FOR i IN 1..3 LOOP
        v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl));
        EXIT WHEN v_r->>'phase' <> 'open_items';
        v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', v_chat, 'table', v_tbl, 'question_key', v_r->'ask'->>'key', 'answer', 'skip'));
    END LOOP;
    IF (v_r->>'closed')::boolean IS DISTINCT FROM true OR EXISTS (SELECT 1 FROM finance.setup_session WHERE chat_id = v_chat)
       THEN RAISE EXCEPTION 'FAIL [D1 Abschluss]: %', v_r; END IF;

    -- ---------- Abgelaufen sperrt nichts, wird aufgeraeumt ----------
    INSERT INTO finance.setup_session (profile, chat_id, file_id, file_hash, created_at) VALUES ('trade_republic_v1', 'old', 'x', 'y', now() - interval '8 days');
    IF (finance.fn_setup_next(jsonb_build_object('chat_id', 'old', 'table', v_tbl))->>'code') <> 'no_open_setup' THEN RAISE EXCEPTION 'FAIL [E1 abgelaufen]'; END IF;
    PERFORM finance.fn_setup_begin(jsonb_build_object('chat_id', 'neu', 'file_id', 'n', 'table', v_tbl));
    IF EXISTS (SELECT 1 FROM finance.setup_session WHERE chat_id = 'old') THEN RAISE EXCEPTION 'FAIL [E2 Sweep]'; END IF;
END $$;
ROLLBACK;
