-- ============================================================
-- test_bank_statement_csv -- Monats-Check aus dem Broker-CSV-Export (Paket B)
--   fn_statement_prepare (source:'file', Bank-Export-Datei) + fn_apply_bank_statement + fn_statement_match (kind-Filter).
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
        pg_temp.tr_row(T - 5, 'TRADING', 'SELL', 'FUND', 'Alt ETF', 'IE00TESTOLD1', '-2.0000000000', '30.000000', '60.00', '-1.00', '-0.50', 'id-06'),
        pg_temp.tr_row(T - 4, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-30.000000', '', '', 'id-07', 'Supermarkt'),
        pg_temp.tr_row(T - 3, 'CASH', 'SOMETHING_NEW', '', '', '', '', '', '-2.000000', '', '', 'id-08', 'Neu'),
        pg_temp.tr_row(T - 2, 'TRADING', 'BUY', 'FUND', 'Alt ETF', 'IE00TESTOLD1', '1.0000000000', '31.000000', '-31.00', '-1.00', '', 'id-09'),
        pg_temp.tr_row(T, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-10.000000', '', '', 'id-10', 'Heute'),
        pg_temp.tr_row(T - 25, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-99.000000', '', '', 'id-11', 'Alt'),
        pg_temp.tr_row(T - 14, 'TRADING', 'BUY', 'FUND', 'Alt ETF', 'IE00TESTOLD1', '3.0000000000', '30.000000', '-90.00', '-1.00', '', 'id-12'),
        -- Krypto-Kauf ohne Krypto-Depot (nur ein Aktien-Depot) -> security_unknown, nie ins Aktien-Depot
        pg_temp.tr_row(T - 7, 'TRADING', 'BUY', 'CRYPTO', 'Bitcoin', 'BTC', '0.0010000000', '20000.000000', '-20.00', '', '', 'id-14'),
        -- Verkauf aus dem Sparplan-Kauf DIESES Exports (Holding entsteht erst beim Buchen) -> gebucht, kein oversell
        pg_temp.tr_row(T - 1, 'TRADING', 'SELL', 'FUND', 'Sparplan ETF', 'IE00TESTSP01', '-0.5000000000', '90.000000', '45.00', '-1.00', '', 'id-15'));
    -- Zeitraum-Summe: 200 - 50 - 41 + 3.75 + 58.50 (Verkauf netto nach Steuer) - 30 - 2 - 32 - 91 - 20 + 44 = 40.25
    -- -> Stand gestern 1040.25, heute -10 -> 1030.25 (deutsch geschrieben wie vom Nutzer genannt)
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_bc_tr__', 'closing_balance', '1.030,25',
                              'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows));

    -- ---------- Ablehnungen ohne Karte ----------
    v_res := finance.fn_statement_prepare(v_p - 'closing_balance');
    IF v_res->>'code' IS DISTINCT FROM 'closing_balance_required' OR v_res ? 'card_lines' THEN
        RAISE EXCEPTION 'FAIL [C1 Owner-Saldo Pflicht]: %', v_res;
    END IF;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('table', jsonb_build_object('rows', '[["a","b"]]'::jsonb)));
    IF v_res->>'code' IS DISTINCT FROM 'export_profile_unknown' THEN RAISE EXCEPTION 'FAIL [C2 fremdes Profil]: %', v_res; END IF;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('table', jsonb_build_object(
                 'rows', jsonb_build_array(v_hdr) || v_rows || jsonb_build_array(jsonb_set(v_rows->0, '{2}', '"JUNIOR"')))));
    IF v_res->>'code' IS DISTINCT FROM 'multiple_sub_accounts' THEN RAISE EXCEPTION 'FAIL [C3 Unterkonten]: %', v_res; END IF;
    -- Bank eingetragen: ein Konto ohne Bank hielte der Konto-Waechter neben __t_bc_tr__ fuer geraten (export_account_mismatch)
    PERFORM finance.fn_create_account('{"name":"__t_bc_nostart__","account_type":"cash","currency":"EUR","bank":"Trade Republic"}'::jsonb);
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_bc_nostart__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'no_starting_point' THEN RAISE EXCEPTION 'FAIL [C4 kein Startpunkt]: %', v_res; END IF;
    RAISE NOTICE 'PASS [C1-C4 Ablehnungen]';

    -- ---------- Vorschau ----------
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [C5 prepare ok]: %', v_prep; END IF;
    IF (v_prep->>'period_start')::date <> T - 19 OR (v_prep->>'period_end')::date <> T - 1
       OR (v_prep->>'closing_balance')::numeric <> 1040.25 OR (v_prep->>'after_period')::numeric <> -10
       OR (v_prep->>'owner_balance')::numeric <> 1030.25 OR v_prep->>'balance_source' <> 'owner' THEN
        RAISE EXCEPTION 'FAIL [C6 Zeitraum + Saldo]: %', v_prep;
    END IF;
    IF (v_prep->>'drift')::numeric <> 0 OR (v_prep->>'lump')::numeric <> 57.00 THEN
        RAISE EXCEPTION 'FAIL [C7 drift 0, Rest 57]: drift % lump %', v_prep->>'drift', v_prep->>'lump';
    END IF;
    IF (v_prep->>'unmatched_out')::numeric <> -32 OR (v_prep->>'unmatched_in')::numeric <> 200 THEN
        RAISE EXCEPTION 'FAIL [C8 Wertpapiere nie in unmatched]: out % in %', v_prep->>'unmatched_out', v_prep->>'unmatched_in';
    END IF;
    IF jsonb_array_length(v_prep->'matched') <> 1 OR v_prep->'matched'->0->>'kind' <> 'savings_plan'
       OR (v_prep->'matched'->0->>'shares')::numeric <> 0.6 OR (v_prep->'matched'->0->>'shares_estimated')::boolean THEN
        RAISE EXCEPTION 'FAIL [C9 Sparplan exakt]: %', v_prep->'matched';
    END IF;
    IF jsonb_array_length(v_prep->'trades') <> 5
       OR (SELECT string_agg(x->>'kind' || ':' || (x->>'amount'), ',' ORDER BY (x->>'line_idx')::int) FROM jsonb_array_elements(v_prep->'trades') x)
          <> 'buy:-41.00,dividend:3.75,sell:59.00,buy:-32.00,sell:44.00'
       OR (SELECT (x->>'tax')::numeric FROM jsonb_array_elements(v_prep->'trades') x WHERE x->>'kind' = 'sell' AND x->>'symbol' = 'ALT') <> -0.50 THEN
        RAISE EXCEPTION 'FAIL [C10 Trades]: %', v_prep->'trades';
    END IF;
    IF jsonb_array_length(v_prep->'trades_blocked') <> 2 OR v_prep->'trades_blocked'->0->>'reason' <> 'covered_by_takeover'
       OR (v_prep->'trades_blocked'->0->>'amount')::numeric <> -91
       OR v_prep->'trades_blocked'->1->>'reason' <> 'security_unknown' OR (v_prep->'trades_blocked'->1->>'amount')::numeric <> -20 THEN
        RAISE EXCEPTION 'FAIL [C11 covered_by_takeover + Krypto ohne Krypto-Depot]: %', v_prep->'trades_blocked';
    END IF;
    IF jsonb_array_length(v_prep->'export_unknown') <> 1 OR (v_prep->'export_unknown'->0->>'cash_amount')::numeric <> -2 THEN
        RAISE EXCEPTION 'FAIL [C12 export_unknown]: %', v_prep->'export_unknown';
    END IF;
    IF jsonb_array_length(v_prep->'seen_refs') <> 11 OR (v_prep->>'late_count')::int <> 0 THEN
        RAISE EXCEPTION 'FAIL [C13 seen_refs/late]: %', v_prep->'seen_refs';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_owner_balance')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_trades')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_opening') THEN
        RAISE EXCEPTION 'FAIL [C14 Karte]: %', v_prep->'card_lines';
    END IF;
    -- Rest +57 aus offenen Ein- UND Ausgaengen ist ein Saldo: weder "Alltagsausgaben" noch ein einzelner "ungeklaerter
    -- Eingang" (Befund KW 45)
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c
                   WHERE c->>'label' = 'finance.label.statement_rest_net' AND (c->>'value')::numeric = 57)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c
                  WHERE c->>'label' IN ('finance.label.statement_everyday', 'finance.label.statement_unexplained_in')) THEN
        RAISE EXCEPTION 'FAIL [C14b Rest heisst Saldo]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [C5-C14 Vorschau]';

    -- ---------- Buchung ----------
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [C15 apply]: %', v_app; END IF;
    IF (v_app->>'trades_booked')::int <> 5 OR (v_app->>'balance_after')::numeric <> 1040.25
       OR (v_app->>'lump_amount')::numeric <> 57.00 OR jsonb_array_length(v_app->'savings_plan_estimated') <> 0 THEN
        RAISE EXCEPTION 'FAIL [C16 apply Zahlen]: %', v_app;
    END IF;
    -- Rest getrennt nach Richtung (Netto-Differenz, eines ist 0); booked_count = 1 Sparplan (Trades separat)
    IF (v_app->>'rest_inflow')::numeric IS DISTINCT FROM 57.00 OR (v_app->>'rest_outflow')::numeric IS DISTINCT FROM 0
       OR (v_app->>'booked_count')::int IS DISTINCT FROM 1 OR jsonb_array_length(v_app->'transfers') <> 0 THEN
        RAISE EXCEPTION 'FAIL [C16b rest_inflow 57, booked_count 1]: %', v_app;
    END IF;
    -- Rest getrennt: offene Eingaenge 200, Ausgaenge -32, Sonstiges (blockierte Trades, unbekannte Zeile) -111 = 57
    IF (v_app->>'unmatched_in')::numeric IS DISTINCT FROM 200 OR (v_app->>'unmatched_out')::numeric IS DISTINCT FROM -32
       OR (v_app->>'rest_other')::numeric IS DISTINCT FROM -111 OR (v_app->>'rest_unexplained')::numeric IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FAIL [C16c Rest getrennt]: %', v_app;
    END IF;
    IF (SELECT shares FROM finance.depot_holdings WHERE id = v_old) <> 9
       OR (SELECT shares FROM finance.depot_holdings WHERE isin = 'IE00TESTNEW1') <> 2
       OR (SELECT h.shares FROM finance.depot_holdings h WHERE h.isin = 'IE00TESTSP01') <> 0.1
       OR NOT EXISTS (SELECT 1 FROM finance.depot_holdings h WHERE h.symbol = 'ALT' AND h.id = v_old)
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_tr AND amount = -0.50
           AND description = 'Steuer Verkauf Alt ETF' AND bank_statement_id = (v_app->>'statement_id')::int) <> 1
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_tr AND shares_estimated) THEN
        RAISE EXCEPTION 'FAIL [C17 Bestaende]';
    END IF;
    IF (SELECT balance_source FROM finance.bank_statements WHERE id = (v_app->>'statement_id')::int) <> 'owner'
       OR (SELECT count(*) FROM finance.statement_seen_refs WHERE statement_id = (v_app->>'statement_id')::int) <> 11
       OR (SELECT count(*) FROM finance.transactions WHERE bank_statement_id = (v_app->>'statement_id')::int AND category::text IN ('buy', 'sell', 'dividend')) <> 6
       OR (SELECT last_reconciled_at FROM finance.accounts WHERE id = v_tr) <> T - 1 THEN
        RAISE EXCEPTION 'FAIL [C18 Aggregat + Herkunft]';
    END IF;
    RAISE NOTICE 'PASS [C15-C18 Buchung]';

    -- derselbe Export noch einmal -> schon bestaetigt (keine Doppelbuchung)
    v_res := finance.fn_statement_prepare(v_p);
    IF v_res->>'code' IS DISTINCT FROM 'already_covered' OR (v_res->>'covered_until')::date IS DISTINCT FROM T - 1
       OR (v_res->>'useful_from')::date IS DISTINCT FROM T THEN RAISE EXCEPTION 'FAIL [C19 erneut]: %', v_res; END IF;

    -- ---------- Spaete Zeile + Stufe 0 ----------
    -- Simuliert den naechsten Export: der vorige CSV-Abgleich endete heute-3 (Zeitraum heute-19..heute-3).
    UPDATE finance.bank_statements SET period_end = T - 3 WHERE id = (v_app->>'statement_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 3 WHERE id = v_tr;
    -- der Kauf ALT (Export heute-2) liegt im System VOR dem Schnitt (von Hand frueher datiert) -> trotzdem Stufe 0
    UPDATE finance.transactions SET transaction_date = T - 4
    WHERE holding_id = v_old AND category::text = 'buy' AND shares = 1 AND bank_statement_id = (v_app->>'statement_id')::int;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('closing_balance', 1025.25,
                 'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows || jsonb_build_array(
                     pg_temp.tr_row(T - 7, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-5.000000', '', '', 'id-13', 'Spaet')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'late_count')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [C20 spaete Zeile]: %', v_res;
    END IF;
    -- im neuen Zeitraum (heute-2..gestern): Kauf ALT (im System heute-4) und Verkauf SPX sind schon gebucht (Stufe 0), die spaete Zeile zaehlt
    IF (SELECT count(*) FROM jsonb_array_elements(v_res->'already_booked') b WHERE (b->>'trade')::boolean) <> 2
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

-- ============================================================
-- Ehrliche Rest-Bezeichnung (Befund 2026-11-03): Alltagsausgaben nur, wenn Abgaenge (mit Export-Luecke) den Rest erklaeren;
-- ohne jede Erklaerung "Ungeklaerter Abgang", gemischt "Rest" mit Notiz. Werte erfunden, Startsaldo 1000 am Stichtag heute-20.
-- ============================================================
CREATE FUNCTION pg_temp.rl_acct(p_name text, p_type text DEFAULT 'cash') RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_r JSONB;
BEGIN
    v_r := finance.fn_create_account(jsonb_build_object('name', p_name, 'account_type', p_type, 'currency', 'EUR',
               'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (core.fn_today() - 20)::text));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP %: %', p_name, v_r; END IF;
    RETURN (v_r->>'account_id')::int;
END $$;
-- Export mit App-Stand: Zeilen als Raster
CREATE FUNCTION pg_temp.rl_file(p_name text, p_balance numeric, p_rows jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('source', 'file', 'account_name', p_name, 'closing_balance', p_balance::text,
        'table', jsonb_build_object('rows', jsonb_build_array('["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]'::jsonb) || p_rows));
$$;
CREATE FUNCTION pg_temp.rl_label(p_prep jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT string_agg(c->>'label', ',') FROM jsonb_array_elements(p_prep->'card_lines') c
    WHERE c->>'label' IN ('finance.label.statement_everyday', 'finance.label.statement_rest_net', 'finance.label.statement_unexplained_in',
                          'finance.label.statement_unexplained_out', 'finance.label.statement_other_diff');
$$;
CREATE FUNCTION pg_temp.rl_has(p_prep jsonb, p_key text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_prep->'card_lines') c WHERE c->>'value' = p_key);
$$;
-- "darin"-Zeilen des Rests (Laien-Pruefung 2026-11-06): Betrag je Teil, Anzahl, und ob sie zusammen genau den Rest ergeben
CREATE FUNCTION pg_temp.rl_part(p_prep jsonb, p_label text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT (c->>'value')::numeric FROM jsonb_array_elements(p_prep->'card_lines') c WHERE c->>'label' = p_label;
$$;
CREATE FUNCTION pg_temp.rl_nparts(p_prep jsonb) RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT count(*)::int FROM jsonb_array_elements(p_prep->'card_lines') c WHERE c->>'label' LIKE 'finance.label.statement_rest\_%'
      AND c->>'label' <> 'finance.label.statement_rest_net';
$$;
CREATE FUNCTION pg_temp.rl_parts_sum_ok(p_prep jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT abs(COALESCE((SELECT sum((c->>'value')::numeric) FROM jsonb_array_elements(p_prep->'card_lines') c
                          WHERE c->>'label' IN ('finance.label.statement_rest_in', 'finance.label.statement_rest_out',
                                                'finance.label.statement_rest_pending', 'finance.label.statement_rest_other')), 0)
               - (SELECT (c->>'value')::numeric FROM jsonb_array_elements(p_prep->'card_lines') c
                  WHERE c->>'label' IN ('finance.label.statement_everyday', 'finance.label.statement_rest_net', 'finance.label.statement_unexplained_in',
                                        'finance.label.statement_unexplained_out', 'finance.label.statement_other_diff'))) < 0.005;
$$;
DO $$
DECLARE
    T DATE := core.fn_today();
    v_old JSONB := pg_temp.tr_row(core.fn_today() - 25, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-1.000000', '', '', 'rl-old', 'Vor dem Schnitt');
    v_id INT; v_depot INT; v_prep JSONB; v_app JSONB; v_note JSONB;
BEGIN
    -- R1: Rest < 0, keine Zeile, kein gesperrter Posten -> Ungeklaerter Abgang, eigener Hinweis, nie Alltag
    v_id := pg_temp.rl_acct('__t_rl1__');
    v_prep := finance.fn_statement_prepare(pg_temp.rl_file('__t_rl1__', 900, jsonb_build_array(v_old)));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR (v_prep->>'lump')::numeric <> -100 THEN RAISE EXCEPTION 'FAIL [R1 prepare]: %', v_prep; END IF;
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_unexplained_out'
       OR NOT pg_temp.rl_has(v_prep, 'finance.note.statement_export_gap_unexplained')
       OR pg_temp.rl_part(v_prep, 'finance.label.statement_rest_pending') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [R1 Ungeklaerter Abgang + Hinweis]: %', v_prep->'card_lines';
    END IF;
    v_note := (SELECT c FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'value' = 'finance.note.statement_export_gap_unexplained');
    IF (v_note->'params'->'amount'->>'value')::numeric IS DISTINCT FROM 100 OR v_prep->>'rest_kind' IS DISTINCT FROM 'unexplained_out' THEN
        RAISE EXCEPTION 'FAIL [R1b Hinweis-Betrag, rest_kind]: %', v_note;
    END IF;
    RAISE NOTICE 'PASS [R1 Ungeklaerter Abgang]';

    -- R2: nur Steuerzeile -> Rest (erklaert durch die Zeile), Notiz; kein Ungeklaerter Abgang
    v_id := pg_temp.rl_acct('__t_rl2__');
    v_prep := finance.fn_statement_prepare(pg_temp.rl_file('__t_rl2__', 995, jsonb_build_array(v_old,
        pg_temp.tr_row(T - 5, 'CASH', 'TAX', '', '', '', '', '', '-5.000000', '', '', 'rl2-1', 'Steuer'))));
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_rest_net' OR (v_prep->>'lump')::numeric <> -5
       OR pg_temp.rl_nparts(v_prep) <> 0 THEN   -- ein einziger Teil: keine "darin"-Zeilen
        RAISE EXCEPTION 'FAIL [R2 nur Steuerzeile]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [R2 nur Steuerzeile]';

    -- R3: nur blockierte Zeile (gedruckt, Depot ist nicht buchbar) -> Rest
    v_id := (finance.fn_create_account(jsonb_build_object('name', '__t_rl3__', 'account_type', 'cash', 'currency', 'EUR', 'bank', 'Testbank',
                 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_depot := (finance.fn_create_account(jsonb_build_object('name', '__t_rl3_depot__', 'account_type', 'stocks_depot', 'currency', 'EUR',
                 'settlement_id', v_id, 'account_number', 'RL3-DEPOT'))->>'account_id')::int;
    v_prep := finance.fn_statement_prepare(jsonb_build_object('account_name', '__t_rl3__', 'currency', 'EUR', 'period_start', T - 19, 'period_end', T - 1,
        'opening_balance', 1000, 'closing_balance', 950, 'lines', jsonb_build_array(
            jsonb_build_object('date', T - 5, 'amount', -50, 'counterparty', 'Depot', 'counterparty_iban', 'RL3-DEPOT'))));
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_rest_net' OR jsonb_array_length(v_prep->'blocked') <> 1
       OR pg_temp.rl_nparts(v_prep) <> 0 THEN
        RAISE EXCEPTION 'FAIL [R3 nur blockierte Zeile]: %', v_prep;
    END IF;
    -- R3b: Abgaenge + gesperrte Zeile -> Rest, "darin"-Zeilen nennen offene Abgaenge und den uebrigen Teil (zusammen = Rest)
    v_prep := finance.fn_statement_prepare(jsonb_build_object('account_name', '__t_rl3__', 'currency', 'EUR', 'period_start', T - 19, 'period_end', T - 1,
        'opening_balance', 1000, 'closing_balance', 920, 'lines', jsonb_build_array(
            jsonb_build_object('date', T - 5, 'amount', -50, 'counterparty', 'Depot', 'counterparty_iban', 'RL3-DEPOT'),
            jsonb_build_object('date', T - 4, 'amount', -30, 'counterparty', 'Laden'))));
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_rest_net' OR pg_temp.rl_nparts(v_prep) <> 2
       OR pg_temp.rl_part(v_prep, 'finance.label.statement_rest_out') IS DISTINCT FROM -30
       OR pg_temp.rl_part(v_prep, 'finance.label.statement_rest_other') IS DISTINCT FROM -50
       OR NOT pg_temp.rl_parts_sum_ok(v_prep) THEN
        RAISE EXCEPTION 'FAIL [R3b Abgaenge + gesperrte Zeile]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [R3 gesperrte Zeile]';

    -- R4: Eingang offen, keine Abgaenge, Rest < 0 -> Rest
    v_id := pg_temp.rl_acct('__t_rl4__');
    v_prep := finance.fn_statement_prepare(pg_temp.rl_file('__t_rl4__', 950, jsonb_build_array(v_old,
        pg_temp.tr_row(T - 5, 'CASH', 'CUSTOMER_INPAYMENT', '', '', '', '', '', '50.000000', '', '', 'rl4-1', 'Eingang'))));
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_rest_net' OR (v_prep->>'lump')::numeric <> -50
       OR (v_prep->>'unmatched_in')::numeric <> 50 OR (v_prep->>'unmatched_out')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [R4 Eingang + negativer Rest]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [R4 Eingang + negativer Rest]';

    -- R5: Rest aus Abgaengen allein -> Alltagsausgaben, kein neuer Hinweis
    v_id := pg_temp.rl_acct('__t_rl5__');
    v_prep := finance.fn_statement_prepare(pg_temp.rl_file('__t_rl5__', 970, jsonb_build_array(v_old,
        pg_temp.tr_row(T - 5, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-30.000000', '', '', 'rl5-1', 'Laden'))));
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_everyday'
       OR pg_temp.rl_nparts(v_prep) <> 0 THEN
        RAISE EXCEPTION 'FAIL [R5 Abgaenge allein]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [R5 Abgaenge allein]';

    -- R6: Abgaenge plus Export-Luecke -> Alltagsausgaben, "darin noch vorgemerkt" als Zeile (vorher Hinweis), Summe = Rest
    v_id := pg_temp.rl_acct('__t_rl6__');
    v_prep := finance.fn_statement_prepare(pg_temp.rl_file('__t_rl6__', 950, jsonb_build_array(v_old,
        pg_temp.tr_row(T - 5, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-30.000000', '', '', 'rl6-1', 'Laden'))));
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_everyday'
       OR pg_temp.rl_part(v_prep, 'finance.label.statement_rest_pending') IS DISTINCT FROM -20
       OR pg_temp.rl_part(v_prep, 'finance.label.statement_rest_out') IS DISTINCT FROM -30
       OR NOT pg_temp.rl_parts_sum_ok(v_prep)
       OR pg_temp.rl_has(v_prep, 'finance.note.statement_export_gap_unexplained') THEN
        RAISE EXCEPTION 'FAIL [R6 Abgaenge + Luecke]: %', v_prep->'card_lines';
    END IF;
    v_app := finance.fn_apply_bank_statement(pg_temp.rl_file('__t_rl6__', 950, jsonb_build_array(v_old,
        pg_temp.tr_row(T - 5, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-30.000000', '', '', 'rl6-1', 'Laden')))
        || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'export_gap')::numeric IS DISTINCT FROM -20 OR v_app->>'rest_kind' IS DISTINCT FROM 'everyday' THEN
        RAISE EXCEPTION 'FAIL [R6b export_gap + rest_kind in der Rueckgabe]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [R6 Abgaenge + Luecke]';

    -- R7: Export beginnt zu spaet: dessen Warnung behaelt den Vorrang vor dem neuen Hinweis
    v_id := pg_temp.rl_acct('__t_rl7__');
    v_prep := finance.fn_statement_prepare(pg_temp.rl_file('__t_rl7__', 900, jsonb_build_array(
        pg_temp.tr_row(T - 5, 'CASH', 'TAX', '', '', '', '', '', '-5.000000', '', '', 'rl7-1', 'Steuer'))));
    IF NOT pg_temp.rl_has(v_prep, 'finance.note.statement_export_starts_late')
       OR pg_temp.rl_has(v_prep, 'finance.note.statement_export_gap_unexplained') THEN
        RAISE EXCEPTION 'FAIL [R7 Export beginnt zu spaet]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [R7 Vorrang spaeter Export]';

    -- R8: Nicht-Cash-Konto mit Luecke < 0: bleibt Sonstige Abweichung
    v_id := pg_temp.rl_acct('__t_rl8__', 'p2p');
    v_prep := finance.fn_statement_prepare(pg_temp.rl_file('__t_rl8__', 900, jsonb_build_array(v_old)));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_other_diff' THEN
        RAISE EXCEPTION 'FAIL [R8 Nicht-Cash]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [R8 Nicht-Cash]';

    -- R9: gedruckter Auszug, Rest > 0 ohne Zeilen (Buchung, die der Auszug nicht kennt): bleibt Ungeklaerter Eingang
    v_id := (finance.fn_create_account(jsonb_build_object('name', '__t_rl9__', 'account_type', 'cash', 'currency', 'EUR', 'bank', 'Testbank',
                 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    PERFORM finance.fn_book_transaction(jsonb_build_object('account_id', v_id, 'amount', 40, 'direction', 'outflow', 'category', 'other',
                 'transaction_date', (T - 6)::text, 'description', 'Von Hand'));
    v_prep := finance.fn_statement_prepare(jsonb_build_object('account_name', '__t_rl9__', 'currency', 'EUR', 'period_start', T - 19, 'period_end', T - 1,
        'opening_balance', 1000, 'closing_balance', 1000, 'lines', '[]'::jsonb));
    IF pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_unexplained_in' OR (v_prep->>'lump')::numeric <> 40 THEN
        RAISE EXCEPTION 'FAIL [R9 gedruckt, Rest > 0]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [R9 Ungeklaerter Eingang bleibt]';
END $$;

-- ---------- Zinsen, die das System vor der Bank bucht (Owner-Entscheid: Buchung bleibt): nichts zaehlt doppelt ----------
DO $$
DECLARE
    T DATE := core.fn_today();
    v_id INT; v_tx INT; v_p JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    v_id := pg_temp.rl_acct('__t_rl_int__');
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description, interest_period_end)
    VALUES (v_id, 5, T - 10, 'interest', 'Zinsen', T - 10) RETURNING id INTO v_tx;
    -- erster Export: Zeile fehlt, App-Stand ohne die Zinsen -> Rest -5, Kandidat nennt die Buchung
    v_p := pg_temp.rl_file('__t_rl_int__', 1000, jsonb_build_array(
        pg_temp.tr_row(T - 25, 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-1.000000', '', '', 'int-old', 'Alt')));
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'lump')::numeric <> -5 OR (v_prep->>'unmatched_out')::numeric <> 0
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'difference_candidates') c WHERE (c->>'transaction_id')::int = v_tx)
       OR pg_temp.rl_label(v_prep) IS DISTINCT FROM 'finance.label.statement_unexplained_out' THEN
        RAISE EXCEPTION 'FAIL [I1 Rest + Kandidat]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR (v_app->>'balance_after')::numeric <> 1000 THEN RAISE EXCEPTION 'FAIL [I2 apply]: %', v_app; END IF;
    -- Folge-Export (Schnitt heute-3 nachgestellt): die Bank zeigt die Zinsen jetzt
    UPDATE finance.transactions SET transaction_date = T - 3 WHERE account_id = v_id AND category = 'reconciliation';
    UPDATE finance.bank_statements SET period_end = T - 3 WHERE id = (v_app->>'statement_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 3 WHERE id = v_id;
    v_p := pg_temp.rl_file('__t_rl_int__', 1005, jsonb_build_array(
        pg_temp.tr_row(T - 2, 'CASH', 'INTEREST_PAYMENT', '', '', '', '', '', '5.000000', '', '', 'int-new', 'Zinsen')));
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR (v_prep->>'unmatched_out')::numeric <> 0 THEN RAISE EXCEPTION 'FAIL [I3 prepare]: %', v_prep; END IF;
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR (v_app->>'balance_after')::numeric <> 1005
       OR (v_app->>'unmatched_out')::numeric <> 0
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_id AND category = 'interest') <> 1 THEN
        RAISE EXCEPTION 'FAIL [I4 keine zweite Buchung, Stand stimmt, Alltag 0]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [Zinsen vor der Bank: nichts doppelt]';
END $$;
ROLLBACK;
