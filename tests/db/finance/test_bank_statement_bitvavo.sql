-- ============================================================
-- test_bank_statement_bitvavo -- Monats-Check mit einem Bitvavo-Export (Profil bitvavo_v1, Buchungsart reward)
--   fn_statement_prepare / fn_apply_bank_statement / fn_void_bank_statement. Werte erfunden, Daten relativ zu heute.
--   Teil 1 (Bitvavo-Datei zuerst): Bitvavo-Konto (cash) mit Verrechnungskonto = Girokonto, Krypto-Depot daran,
--   letzter Abgleich heute-11, ETH-Position mit einem schon gebuchten Ertrag 0.0001 am heute-12.
--   Export: Ertrag ETH heute-12 (vor dem Stichtag), Einzahlung 100 (heute-10), Ertrag BTC VOR dem ersten BTC-Kauf am
--   selben Tag (heute-9), Kauf BTC 60.15 inkl. 0.15, Ertrag ETH heute-9 und heute-6 (gleich gross wie der gebuchte,
--   je 3 Tage Abstand: Stufe 0 darf sie nie als gebucht verwerfen), Kauf Kleinst-Muenze 3 000 000 Stueck fuer 25.00
--   inkl. 0.06 (gebucht -25.00, nie -24.99), Verkauf BTC inkl. Ertrag (heute-5, 64.50). Stand 79.35.
--   Danach: Girokonto-Auszug erkennt die Einzahlung als schon gebucht; Ruecknahme des Bitvavo-Auszugs entfernt Kaeufe,
--   Verkauf und Ertraege (Verkauf nach Ertraegen: Reihenfolge der Storni darf den Bestand nie negativ machen).
--   Teil 2 (Girokonto zuerst): Einzahlung an "Bitvavo" wird per Pool-Regel (Profil statt nur P2P) zum Uebertrag,
--   der Bitvavo-Export danach erkennt sie als schon gebucht.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.bv(p_d date, p_typ text, p_cur text, p_amt text, p_px text, p_paid text, p_fee text, p_status text, p_id text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array('Europe/Amsterdam', p_d::text, '10:00:00', p_typ, p_cur, p_amt,
                             CASE WHEN p_px = '' THEN '' ELSE 'EUR' END, p_px,
                             CASE WHEN p_paid = '' THEN '' ELSE 'EUR' END, p_paid,
                             CASE WHEN p_fee = '' THEN '' ELSE 'EUR' END, p_fee, p_status, p_id, '');
$$;
CREATE FUNCTION pg_temp.bv_hdr() RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT '["Timezone","Date","Time","Type","Currency","Amount","Quote Currency","Quote Price","Received / Paid Currency","Received / Paid Amount","Fee currency","Fee amount","Status","Transaction ID","Address"]'::jsonb;
$$;

-- ---------- Teil 1: Bitvavo-Datei zuerst ----------
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_giro INT; v_bv INT; v_dep INT; v_eth INT;
    v_res  JSONB; v_p JSONB; v_prep JSONB; v_app JSONB; v_s JSONB;
BEGIN
    v_giro := (finance.fn_create_account(jsonb_build_object('name', '__t_bvs_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'account_number', 'DE02120300000000202051',
                 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_bv := (finance.fn_create_account(jsonb_build_object('name', '__t_bvs_bv__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Bitvavo', 'opening_balance', 0, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    -- Bitvavo zahlt nur auf das verifizierte Girokonto aus (Muster Bondora): Verrechnungskonto des Bitvavo-Kontos
    v_res := finance.fn_set_account(jsonb_build_object('account_id', v_bv, 'settlement_id', v_giro));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT settlement_account_id FROM finance.accounts WHERE id = v_bv) IS DISTINCT FROM v_giro THEN
        RAISE EXCEPTION 'FAIL [S0 Verrechnungskonto fuer das Bitvavo-Konto]: %', v_res; END IF;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_bvs_dep__', 'account_type', 'crypto_depot',
                 'currency', 'EUR', 'settlement_id', v_bv))->>'account_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 11 WHERE id = v_bv;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_dep, NULL, 'ETH', 'ETH', 'EUR') RETURNING id INTO v_eth;
    INSERT INTO finance.transactions (account_id, holding_id, category, amount, shares, transaction_date, description)
    VALUES (v_bv, v_eth, 'reward', 0, 0.0001, T - 12, 'Staking ETH');

    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_bvs_bv__', 'closing_balance', 79.35,
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.bv_hdr(),
            pg_temp.bv(T-12, 'staking', 'ETH',   '0.00010000',  '',         '',       '',     'Distributed', 'bs-01'),
            pg_temp.bv(T-10, 'deposit', 'EUR',   '100.00',      '',         '',       '0.00', 'Completed',   'bs-02'),
            pg_temp.bv(T-9,  'staking', 'BTC',   '0.00001000',  '',         '',       '',     'Distributed', 'bs-03'),
            pg_temp.bv(T-9,  'buy',     'BTC',   '0.00100000',  '60000.00', '-60.15', '0.15', 'Completed',   'bs-04'),
            pg_temp.bv(T-9,  'staking', 'ETH',   '0.00010000',  '',         '',       '',     'Distributed', 'bs-05'),
            pg_temp.bv(T-8,  'buy',     'XMEME', '3000000',     '0.00000831', '-25.00', '0.06', 'Completed', 'bs-06'),
            pg_temp.bv(T-6,  'staking', 'ETH',   '0.00010000',  '',         '',       '',     'Distributed', 'bs-07'),
            pg_temp.bv(T-5,  'sell',    'BTC',   '-0.00101000', '63960.00', '64.50',  '0.10', 'Completed',   'bs-08'))));

    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR (v_prep->>'lump')::numeric <> 0 OR (v_prep->>'drift')::numeric <> 0
       OR jsonb_array_length(v_prep->'trades_blocked') <> 0 THEN
        RAISE EXCEPTION 'FAIL [B1 prepare]: %', v_prep; END IF;
    -- Karte: je Muenze eine Summenzeile der Ertraege (BTC, ETH), keine Einzelzeilen
    IF (SELECT count(*) FROM regexp_matches((v_prep->'card_lines')::text, 'finance\.tpl\.statement_trade_reward', 'g')) <> 2 THEN
        RAISE EXCEPTION 'FAIL [B2 Karte: Summenzeile je Muenze]: %', v_prep->'card_lines'; END IF;
    -- centgenau: der Kauf bucht genau den bezahlten Betrag
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'trades') x WHERE x->>'kind' = 'buy' AND (x->>'amount')::numeric = -25.00)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'trades') x WHERE x->>'kind' = 'buy' AND (x->>'amount')::numeric = -60.15)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'trades') x WHERE x->>'kind' = 'sell' AND (x->>'amount')::numeric = 64.50) THEN
        RAISE EXCEPTION 'FAIL [B3 Betraege centgenau]: %', v_prep->'trades'; END IF;
    RAISE NOTICE 'PASS [B1-B3 Vorschau]';

    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR finance.fn_get_balance(v_bv) <> 79.35 OR finance.fn_get_balance(v_giro) <> 900 THEN
        RAISE EXCEPTION 'FAIL [B4 apply + Salden]: % / bv % giro %', v_app, finance.fn_get_balance(v_bv), finance.fn_get_balance(v_giro); END IF;
    IF (SELECT string_agg(symbol || ':' || shares::text, ',' ORDER BY symbol) FROM finance.depot_holdings WHERE account_id = v_dep)
       IS DISTINCT FROM 'BTC:0.00000000,ETH:0.00030000,XMEME:3000000.00000000' THEN
        RAISE EXCEPTION 'FAIL [B5 Bestaende inkl. Ertraege]: %', (SELECT jsonb_agg(to_jsonb(h)) FROM finance.depot_holdings h WHERE account_id = v_dep); END IF;
    IF (SELECT count(*) FROM finance.transactions WHERE account_id = v_bv AND category::text = 'reward' AND amount = 0
          AND bank_statement_id IS NOT NULL) <> 3
       OR (SELECT amount FROM finance.transactions t JOIN finance.depot_holdings h ON h.id = t.holding_id
           WHERE h.symbol = 'XMEME' AND h.account_id = v_dep AND t.category::text = 'buy') IS DISTINCT FROM -25.00 THEN
        RAISE EXCEPTION 'FAIL [B6 Ertraege + Kleinst-Muenze centgenau]'; END IF;
    RAISE NOTICE 'PASS [B4-B6 Buchung]';

    -- Re-Import derselben Datei: nichts Neues
    v_res := finance.fn_statement_prepare(v_p);
    IF v_res->>'code' IS DISTINCT FROM 'already_covered' THEN RAISE EXCEPTION 'FAIL [B7 Re-Import]: %', v_res; END IF;

    -- Girokonto-Auszug danach: die Einzahlung an Bitvavo ist schon gebucht (Uebertrag), kein Rest
    v_s := jsonb_build_object('account_name', '__t_bvs_giro__', 'currency', 'EUR', 'period_start', T - 19, 'period_end', T - 1,
        'opening_balance', 1000, 'closing_balance', 900,
        'lines', jsonb_build_array(jsonb_build_object('date', T - 10, 'amount', -100, 'counterparty', 'Bitvavo B.V.', 'purpose', 'Einzahlung')));
    v_res := finance.fn_statement_prepare(v_s);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric <> 0
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'already_booked') b WHERE (b->>'amount')::numeric = -100) THEN
        RAISE EXCEPTION 'FAIL [B8 Girokonto erkennt die Einzahlung]: %', v_res; END IF;
    RAISE NOTICE 'PASS [B7-B8 Re-Import + Gegenseite]';

    -- Ruecknahme: Kaeufe, Verkauf (nach Ertraegen) und die zwei neuen Ertraege weg, der alte Ertrag bleibt
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_bv));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR finance.fn_get_balance(v_bv) <> 0
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_bv AND category::text = 'reward') <> 1
       OR (SELECT shares FROM finance.depot_holdings WHERE id = v_eth) <> 0.0001
       OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE account_id = v_dep AND shares <> 0 AND id <> v_eth) THEN
        RAISE EXCEPTION 'FAIL [B9 Ruecknahme]: %', v_res; END IF;
    RAISE NOTICE 'PASS [B9 Ruecknahme]';
END $$;

-- ---------- Teil 2: Girokonto zuerst ----------
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_giro INT; v_bv INT;
    v_res  JSONB; v_s JSONB; v_p JSONB; v_app JSONB;
BEGIN
    v_giro := (finance.fn_create_account(jsonb_build_object('name', '__t_bvg_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'account_number', 'DE02500105170137075030',
                 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_bv := (finance.fn_create_account(jsonb_build_object('name', '__t_bvg_bv__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Bitvavo', 'opening_balance', 0, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;

    v_s := jsonb_build_object('account_name', '__t_bvg_giro__', 'currency', 'EUR', 'period_start', T - 19, 'period_end', T - 1,
        'opening_balance', 1000, 'closing_balance', 900,
        'lines', jsonb_build_array(jsonb_build_object('date', T - 10, 'amount', -100, 'counterparty', 'Bitvavo B.V.', 'purpose', 'Einzahlung')));
    -- Teil 1 laeuft in derselben Transaktion: sein Bitvavo-Konto ist ein zweiter Kandidat -> der Agent fragt nach
    v_res := finance.fn_statement_prepare(v_s);
    IF v_res->>'code' IS DISTINCT FROM 'transfer_choice_required'
       OR v_res->'candidates' <> '["__t_bvs_bv__", "__t_bvg_bv__"]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [G0 zwei Bitvavo-Konten -> Rueckfrage]: %', v_res; END IF;
    v_s := v_s || jsonb_build_object('transfer_account', '__t_bvg_bv__');
    v_res := finance.fn_statement_prepare(v_s);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric <> 0
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'matched') m
                      WHERE (m->>'amount')::numeric = -100 AND (m->>'other_account_id')::int = v_bv) THEN
        RAISE EXCEPTION 'FAIL [G1 Pool-Regel nach Profil]: %', v_res; END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_res->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR finance.fn_get_balance(v_bv) <> 100 THEN
        RAISE EXCEPTION 'FAIL [G2 Uebertrag gebucht]: %', v_app; END IF;

    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_bvg_bv__', 'closing_balance', 100,
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.bv_hdr(),
            pg_temp.bv(T-10, 'deposit', 'EUR', '100.00', '', '', '0.00', 'Completed', 'bg-01'))));
    v_res := finance.fn_statement_prepare(v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric <> 0
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'already_booked') b WHERE (b->>'amount')::numeric = 100) THEN
        RAISE EXCEPTION 'FAIL [G3 Bitvavo-Export erkennt den Uebertrag]: %', v_res; END IF;
    RAISE NOTICE 'PASS [G0-G3 Girokonto zuerst]';
END $$;

-- ---------- Teil 3: Stueckpreis unter 5e-9 (rundet auf 8 Stellen zu 0) ----------
--   1 000 000 000 Stueck fuer 1.00 inkl. 0.01 Gebuehr: kein buchbarer Kurs -> korrigierbare Ablehnung als Daten
--   (trades_blocked not_bookable, Karten-Grund), nie ein Abbruch in apply.
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_bv INT; v_res JSONB;
BEGIN
    v_bv := (finance.fn_create_account(jsonb_build_object('name', '__t_bvp_bv__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Bitvavo', 'opening_balance', 10, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_bvp_dep__', 'account_type', 'crypto_depot',
                 'currency', 'EUR', 'settlement_id', v_bv));
    v_res := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'account_name', '__t_bvp_bv__', 'closing_balance', 9,
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.bv_hdr(),
            pg_temp.bv(T-5, 'buy', 'XTINY', '1000000000', '0.000000001', '-1.00', '0.01', 'Completed', 'bp-01')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'trades') <> 0
       OR jsonb_array_length(v_res->'trades_blocked') <> 1 OR v_res->'trades_blocked'->0->>'reason' <> 'not_bookable'
       OR (v_res->'card_lines')::text NOT LIKE '%finance.tpl.statement_trade_not_bookable%' THEN
        RAISE EXCEPTION 'FAIL [P1 Stueckpreis unter 5e-9 -> not_bookable]: %', v_res; END IF;
    RAISE NOTICE 'PASS [P1 Stueckpreis unter 5e-9]';

    -- Verkauf, dessen Gebuehr den Erloes uebersteigt: Gutschrift waere negativ -> not_bookable, nie ein Abbruch in apply
    v_res := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'account_name', '__t_bvp_bv__', 'closing_balance', 9.50,
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.bv_hdr(),
            pg_temp.bv(T-5, 'buy',  'XFEE', '1.00000000',  '1.00', '-1.00', '0.00', 'Completed', 'bp-02'),
            pg_temp.bv(T-4, 'sell', 'XFEE', '-1.00000000', '0.50', '-0.50', '1.00', 'Completed', 'bp-03')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'trades_blocked') b WHERE b->>'kind' = 'sell' AND b->>'reason' = 'not_bookable')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'trades') x WHERE x->>'kind' = 'sell') THEN
        RAISE EXCEPTION 'FAIL [P2 Verkauf mit Gebuehr ueber dem Erloes]: %', v_res; END IF;
    RAISE NOTICE 'PASS [P2 Verkauf mit Gebuehr ueber dem Erloes]';
END $$;

-- ---------- Teil 4: nicht buchbare Ertraege, offene Vorgaenge ----------
--   Kein Krypto-Depot: zwei Ertraege derselben Muenze sind security_unknown -> EINE Summenzeile ohne Euro-Betrag.
--   Ein offener Vorgang (Pending) steht mit Grund auf der Karte und gilt nie als gesehen (statement_seen_refs).
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_res JSONB;
BEGIN
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_bvq_bv__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Bitvavo', 'opening_balance', 10, 'opening_balance_date', (T - 20)::text));
    v_res := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'account_name', '__t_bvq_bv__', 'closing_balance', 10,
        'table', jsonb_build_object('rows', jsonb_build_array(pg_temp.bv_hdr(),
            pg_temp.bv(T-6, 'staking',    'ETH', '0.00010000', '', '', '',     'Distributed', 'bq-01'),
            pg_temp.bv(T-5, 'staking',    'ETH', '0.00020000', '', '', '',     'Distributed', 'bq-02'),
            pg_temp.bv(T-4, 'withdrawal', 'EUR', '-50.00',     '', '', '0.00', 'Pending',     'bq-03')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'trades_blocked') <> 2
       OR (SELECT count(*) FROM regexp_matches((v_res->'card_lines')::text, 'finance\.tpl\.statement_trade_reward_blocked_row', 'g')) <> 1
       OR (v_res->'card_lines')::text LIKE '%finance.tpl.statement_trade_blocked_row%' THEN
        RAISE EXCEPTION 'FAIL [Q1 gesperrte Ertraege als eine Summe]: %', v_res->'card_lines'; END IF;
    IF (v_res->'card_lines')::text NOT LIKE '%finance.tpl.statement_export_reason_not_completed%'
       OR (v_res->'seen_refs') ? md5('bq-03') OR NOT (v_res->'seen_refs') ? md5('bq-01') THEN
        RAISE EXCEPTION 'FAIL [Q2 offener Vorgang: Grund auf der Karte, nie gesehen]: %', v_res; END IF;
    RAISE NOTICE 'PASS [Q1-Q2 gesperrte Ertraege, offener Vorgang]';
END $$;
ROLLBACK;
