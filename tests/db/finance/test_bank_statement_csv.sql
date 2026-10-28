-- ============================================================
-- test_bank_statement_csv -- Monats-Check aus dem Broker-CSV-Export (Paket B)
--   fn_statement_prepare (source:'csv') + fn_apply_bank_statement + fn_statement_match (kind-Filter).
--   Werte erfunden, Daten relativ zu core.fn_today(). Szenario: TR-Cashkonto mit Startsaldo 1000 (Stichtag heute-20),
--   Depot daran, Bestandsuebernahme ALT (10 Stueck, heute-12), Sparplan SPX (50/Monat, Faelligkeit im Zeitraum).
--   Export: Einzahlung +200 (netto), Sparplan-Kauf 0.6 Stueck, Kauf NEU (neue Position), Kauf ALT vor der Uebernahme
--   (steckt darin -> covered_by_takeover), Dividende ALT, Verkauf ALT, Kauf ALT danach, Karte -30, unbekannter Typ -2,
--   Zeile vor dem Schnitt (ignoriert), Zeile von heute (after_period). Owner-Saldo = Stand jetzt laut App.
--   Erwartet: drift 0, lump = 200 - 30 - 2 - 91 (Uebernahme-Kauf) = 77, unmatched_out ohne Wertpapier-Zeilen.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.tr_row(p_d date, p_cat text, p_typ text, p_cls text, p_name text, p_sym text, p_sh text,
                               p_px text, p_amt text, p_fee text, p_tax text, p_id text, p_desc text DEFAULT '')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text || 'T10:00:00Z', p_d::text, 'DEFAULT', p_cat, p_typ, p_cls, p_name, p_sym, p_sh,
                             p_px, p_amt, p_fee, p_tax, 'EUR', '', '', '', p_desc, p_id, '', '', '', '');
$$;
DO $$
DECLARE
    T       DATE := core.fn_today();
    v_hdr   JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_tr    INT;
    v_depot INT;
    v_due   DATE;
    v_res   JSONB;
    v_rows  JSONB;
    v_p     JSONB;
    v_prep  JSONB;
    v_app   JSONB;
    v_old   INT;
    v_n     INT;
BEGIN
    -- ---------- Setup ----------
    v_res := finance.fn_create_account(jsonb_build_object('name', '__t_bc_tr__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP tr: %', v_res; END IF;
    v_tr := (v_res->>'account_id')::int;
    v_depot := (finance.fn_create_account(jsonb_build_object('name', '__t_bc_depot__', 'account_type', 'stocks_depot',
                   'currency', 'EUR', 'settlement_id', v_tr))->>'account_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_tr, 'isin', 'IE00TESTOLD1',
                 'symbol', 'ALT', 'name', 'Alt ETF', 'shares', 10, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 12)::text, 'existing_position', true));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP takeover: %', v_res; END IF;
    v_old := (v_res->>'holding_id')::int;
    v_due := CASE WHEN extract(day FROM T - 10) <= 28 THEN T - 10 ELSE T - 13 END;
    v_res := finance.fn_create_savings_plan(jsonb_build_object('name', '__t_bc_sp__', 'depot_name', '__t_bc_depot__',
                 'isin', 'IE00TESTSP01', 'symbol', 'SPX', 'security_name', 'Sparplan ETF', 'amount', 50,
                 'schedule_interval', 1, 'schedule_unit', 'month',
                 'schedule_day_of_month', extract(day FROM v_due)::int, 'first_payment_date', v_due::text));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP plan: %', v_res; END IF;

    v_rows := jsonb_build_array(
        pg_temp.tr_row(T - 15, 'CASH', 'CUSTOMER_INPAYMENT', '', '', '', '', '', '200.500000', '-0.50', '', 'id-02', 'Top up'),
        pg_temp.tr_row(v_due, 'TRADING', 'BUY', 'FUND', 'Sparplan ETF', 'IE00TESTSP01', '0.6000000000', '83.3333333300', '-50.00', '', '', 'id-03', 'Savings plan execution'),
        pg_temp.tr_row(T - 8, 'TRADING', 'BUY', 'FUND', 'Neu ETF', 'IE00TESTNEW1', '2.0000000000', '20.000000', '-40.00', '-1.00', '', 'id-04'),
        pg_temp.tr_row(T - 6, 'CASH', 'DIVIDEND', 'FUND', 'Alt ETF', 'IE00TESTOLD1', '10.0000000000', '', '5.000000', '', '-1.25', 'id-05'),
        pg_temp.tr_row(T - 5, 'TRADING', 'SELL', 'FUND', 'Alt ETF', 'IE00TESTOLD1', '-2.0000000000', '30.000000', '60.00', '-1.00', '', 'id-06'),
        pg_temp.tr_row(T - 4, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-30.000000', '', '', 'id-07', 'Supermarkt'),
        pg_temp.tr_row(T - 3, 'CASH', 'SOMETHING_NEW', '', '', '', '', '', '-2.000000', '', '', 'id-08', 'Neu'),
        pg_temp.tr_row(T - 2, 'TRADING', 'BUY', 'FUND', 'Alt ETF', 'IE00TESTOLD1', '1.0000000000', '31.000000', '-31.00', '-1.00', '', 'id-09'),
        pg_temp.tr_row(T, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-10.000000', '', '', 'id-10', 'Heute'),
        pg_temp.tr_row(T - 25, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-99.000000', '', '', 'id-11', 'Alt'),
        pg_temp.tr_row(T - 14, 'TRADING', 'BUY', 'FUND', 'Alt ETF', 'IE00TESTOLD1', '3.0000000000', '30.000000', '-90.00', '-1.00', '', 'id-12'));
    -- Zeitraum-Summe: 200 - 50 - 41 + 3.75 + 59 - 30 - 2 - 32 - 91 = 16.75 -> Stand gestern 1016.75, heute -10 -> 1006.75
    v_p := jsonb_build_object('source', 'csv', 'account_name', '__t_bc_tr__', 'closing_balance', 1006.75,
                              'csv', jsonb_build_object('header', v_hdr, 'rows', v_rows));

    -- ---------- Ablehnungen ohne Karte ----------
    v_res := finance.fn_statement_prepare(v_p - 'closing_balance');
    IF v_res->>'code' IS DISTINCT FROM 'closing_balance_required' OR v_res ? 'card_lines' THEN
        RAISE EXCEPTION 'FAIL [C1 Owner-Saldo Pflicht]: %', v_res;
    END IF;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('csv', jsonb_build_object('header', '["a","b"]'::jsonb, 'rows', '[]'::jsonb)));
    IF v_res->>'code' IS DISTINCT FROM 'csv_profile_unknown' THEN RAISE EXCEPTION 'FAIL [C2 fremdes Profil]: %', v_res; END IF;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('csv', jsonb_build_object('header', v_hdr,
                 'rows', v_rows || jsonb_build_array(jsonb_set(v_rows->0, '{2}', '"JUNIOR"')))));
    IF v_res->>'code' IS DISTINCT FROM 'multiple_sub_accounts' THEN RAISE EXCEPTION 'FAIL [C3 Unterkonten]: %', v_res; END IF;
    PERFORM finance.fn_create_account('{"name":"__t_bc_nostart__","account_type":"cash","currency":"EUR"}'::jsonb);
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_bc_nostart__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'no_starting_point' THEN RAISE EXCEPTION 'FAIL [C4 kein Startpunkt]: %', v_res; END IF;
    RAISE NOTICE 'PASS [C1-C4 Ablehnungen]';

    -- ---------- Vorschau ----------
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [C5 prepare ok]: %', v_prep; END IF;
    IF (v_prep->>'period_start')::date <> T - 19 OR (v_prep->>'period_end')::date <> T - 1
       OR (v_prep->>'closing_balance')::numeric <> 1016.75 OR (v_prep->>'after_period')::numeric <> -10
       OR (v_prep->>'owner_balance')::numeric <> 1006.75 OR v_prep->>'balance_source' <> 'owner' THEN
        RAISE EXCEPTION 'FAIL [C6 Zeitraum + Saldo]: %', v_prep;
    END IF;
    IF (v_prep->>'drift')::numeric <> 0 OR (v_prep->>'lump')::numeric <> 77.00 THEN
        RAISE EXCEPTION 'FAIL [C7 drift 0, Rest 77]: drift % lump %', v_prep->>'drift', v_prep->>'lump';
    END IF;
    IF (v_prep->>'unmatched_out')::numeric <> -32 OR (v_prep->>'unmatched_in')::numeric <> 200 THEN
        RAISE EXCEPTION 'FAIL [C8 Wertpapiere nie in unmatched]: out % in %', v_prep->>'unmatched_out', v_prep->>'unmatched_in';
    END IF;
    IF jsonb_array_length(v_prep->'matched') <> 1 OR v_prep->'matched'->0->>'kind' <> 'savings_plan'
       OR (v_prep->'matched'->0->>'shares')::numeric <> 0.6 OR (v_prep->'matched'->0->>'shares_estimated')::boolean THEN
        RAISE EXCEPTION 'FAIL [C9 Sparplan exakt]: %', v_prep->'matched';
    END IF;
    IF jsonb_array_length(v_prep->'trades') <> 4
       OR (SELECT string_agg(x->>'kind' || ':' || (x->>'amount'), ',' ORDER BY (x->>'line_idx')::int) FROM jsonb_array_elements(v_prep->'trades') x)
          <> 'buy:-41.00,dividend:3.75,sell:59.00,buy:-32.00' THEN
        RAISE EXCEPTION 'FAIL [C10 Trades]: %', v_prep->'trades';
    END IF;
    IF jsonb_array_length(v_prep->'trades_blocked') <> 1 OR v_prep->'trades_blocked'->0->>'reason' <> 'covered_by_takeover'
       OR (v_prep->'trades_blocked'->0->>'amount')::numeric <> -91 THEN
        RAISE EXCEPTION 'FAIL [C11 covered_by_takeover]: %', v_prep->'trades_blocked';
    END IF;
    IF jsonb_array_length(v_prep->'csv_unknown') <> 1 OR (v_prep->'csv_unknown'->0->>'cash_amount')::numeric <> -2 THEN
        RAISE EXCEPTION 'FAIL [C12 csv_unknown]: %', v_prep->'csv_unknown';
    END IF;
    IF jsonb_array_length(v_prep->'seen_refs') <> 9 OR (v_prep->>'late_count')::int <> 0 THEN
        RAISE EXCEPTION 'FAIL [C13 seen_refs/late]: %', v_prep->'seen_refs';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_owner_balance')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_trades')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_opening') THEN
        RAISE EXCEPTION 'FAIL [C14 Karte]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [C5-C14 Vorschau]';

    -- ---------- Buchung ----------
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [C15 apply]: %', v_app; END IF;
    IF (v_app->>'trades_booked')::int <> 4 OR (v_app->>'balance_after')::numeric <> 1016.75
       OR (v_app->>'lump_amount')::numeric <> 77.00 OR jsonb_array_length(v_app->'savings_plan_estimated') <> 0 THEN
        RAISE EXCEPTION 'FAIL [C16 apply Zahlen]: %', v_app;
    END IF;
    IF (SELECT shares FROM finance.depot_holdings WHERE id = v_old) <> 9
       OR (SELECT shares FROM finance.depot_holdings WHERE isin = 'IE00TESTNEW1') <> 2
       OR (SELECT h.shares FROM finance.depot_holdings h WHERE h.isin = 'IE00TESTSP01') <> 0.6
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_tr AND shares_estimated) THEN
        RAISE EXCEPTION 'FAIL [C17 Bestaende]';
    END IF;
    IF (SELECT balance_source FROM finance.bank_statements WHERE id = (v_app->>'statement_id')::int) <> 'owner'
       OR (SELECT count(*) FROM finance.statement_seen_refs WHERE statement_id = (v_app->>'statement_id')::int) <> 9
       OR (SELECT count(*) FROM finance.transactions WHERE bank_statement_id = (v_app->>'statement_id')::int AND category::text IN ('buy', 'sell', 'dividend')) <> 5
       OR (SELECT last_reconciled_at FROM finance.accounts WHERE id = v_tr) <> T - 1 THEN
        RAISE EXCEPTION 'FAIL [C18 Aggregat + Herkunft]';
    END IF;
    RAISE NOTICE 'PASS [C15-C18 Buchung]';

    -- derselbe Export noch einmal -> schon bestaetigt (keine Doppelbuchung)
    v_res := finance.fn_statement_prepare(v_p);
    IF v_res->>'code' IS DISTINCT FROM 'already_covered' THEN RAISE EXCEPTION 'FAIL [C19 erneut]: %', v_res; END IF;

    -- ---------- Spaete Zeile + Stufe 0 ----------
    -- Simuliert den naechsten Export: der vorige CSV-Abgleich endete heute-3 (Zeitraum heute-19..heute-3).
    UPDATE finance.bank_statements SET period_end = T - 3 WHERE id = (v_app->>'statement_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 3 WHERE id = v_tr;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('closing_balance', 1001.75,
                 'csv', jsonb_build_object('header', v_hdr, 'rows', v_rows || jsonb_build_array(
                     pg_temp.tr_row(T - 7, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-5.000000', '', '', 'id-13', 'Spaet')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'late_count')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [C20 spaete Zeile]: %', v_res;
    END IF;
    -- im neuen Zeitraum (heute-2..gestern): Kauf ALT heute-2 ist schon gebucht (Stufe 0), die spaete Zeile zaehlt
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'already_booked') b WHERE (b->>'trade')::boolean)
       OR jsonb_array_length(v_res->'trades') <> 0 OR (v_res->>'unmatched_out')::numeric <> -5 THEN
        RAISE EXCEPTION 'FAIL [C21 Stufe 0 Trade + spaet]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [C19-C21 erneut, spaet, Stufe 0]';

    -- ---------- Matcher: Geldzeile trifft nie einen Sparplan ----------
    -- naechste Faelligkeit des Sparplans: gedruckte Zeile (kind NULL) trifft sie, CSV-Geldzeile nie
    SELECT count(*) INTO v_n FROM jsonb_array_elements((finance.fn_statement_match(v_tr, T - 20, v_due + 40, jsonb_build_array(
        jsonb_build_object('date', (v_due + interval '1 month')::date, 'amount', -50))))->'matched');
    IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [C22a Kontrolle: gedruckte Zeile trifft den Sparplan]'; END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements((finance.fn_statement_match(v_tr, T - 20, v_due + 40, jsonb_build_array(
        jsonb_build_object('date', (v_due + interval '1 month')::date, 'amount', -50, 'kind', 'cash'))))->'matched');
    IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [C22 cash trifft keinen Sparplan]'; END IF;
    RAISE NOTICE 'PASS [C22 Matcher kind-Filter]';
END $$;
ROLLBACK;
