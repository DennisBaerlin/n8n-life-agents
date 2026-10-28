-- ============================================================
-- test_fn_broker_csv_normalize -- Golden-File je Profil (Broker-CSV Paket B)
--   finance.fn_broker_csv_normalize / fn_broker_csv_profiles / fn_broker_csv_account_profile.
--   Fixture = Trade-Republic-Spaltenform (nach den Portfolio-Performance-Fixtures TransactionExport01..06), Werte
--   frei erfunden. Deckt: Profil-Erkennung per Header, Cash-Wirkung amount+fee+tax, Kauf/Verkauf (Stueck als Betrag),
--   Krypto ohne ISIN, Dividende netto, Dividenden-Korrektur -> unknown, unbekannter Typ -> unknown_rows (nie still
--   verworfen), date vor datetime, Leerzeile, unlesbare Zahl -> csv_invalid, fremder Header -> csv_profile_unknown.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_hdr JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_rows JSONB := jsonb_build_array(
        -- 2: Einzahlung 120.50 mit 0.50 Gebuehr -> +120.00
        '["2026-09-02T08:00:00Z","2026-09-02","DEFAULT","CASH","CUSTOMER_INPAYMENT","","","","","","120.500000","-0.50","","EUR","","","","Top up","aaaa-0001","","","",""]'::jsonb,
        -- 3: Kauf 3 Stueck @ 20.10 = -60.30, Gebuehr -1.00 -> -61.30
        '["2026-09-03T09:00:00Z","2026-09-03","DEFAULT","TRADING","BUY","FUND","Test ETF","IE00TEST0001","3.0000000000","20.100000","-60.30","-1.00","","EUR","","","","Buy trade","aaaa-0002","","","",""]'::jsonb,
        -- 4: Verkauf -1 Stueck (signiert) @ 21 = +21.00, Gebuehr -1.00 -> +20.00
        '["2026-09-04T09:00:00Z","2026-09-04","DEFAULT","TRADING","SELL","FUND","Test ETF","IE00TEST0001","-1.0000000000","21.000000","21.00","-1.00","","EUR","","","","Sell trade","aaaa-0003","","","",""]'::jsonb,
        -- 5: Krypto-Sparplan 0.0005 BTC -> ISIN NULL, Symbol BTC
        '["2026-09-05T09:00:00Z","2026-09-05","DEFAULT","TRADING","BUY","CRYPTO","Bitcoin","BTC","0.0005000000","50000.0000000000","-25.00","","","EUR","","","","Savings plan execution","aaaa-0004","","","",""]'::jsonb,
        -- 6: Dividende 10.00 brutto, Steuer -2.50 -> +7.50
        '["2026-09-06T23:30:00Z","2026-09-06","DEFAULT","CASH","DIVIDEND","STOCK","Test AG","DE000TEST0002","50.0000000000","","10.000000","","-2.50","EUR","","","","Cash Dividend","aaaa-0005","","","",""]'::jsonb,
        -- 7 + 8: Dividenden-Korrektur (Storno -4.00 + Neu-Buchung +4.00, gleiche ISIN/Stueck) -> beide unknown
        '["2026-09-07T10:00:00Z","2026-09-07","DEFAULT","CASH","DIVIDEND","STOCK","Korr AG","US000TEST003","20.0000000000","","-4.000000","","1.00","EUR","","","","Cash Dividend","aaaa-0006","","","",""]'::jsonb,
        '["2026-09-07T10:01:00Z","2026-09-07","DEFAULT","CASH","DIVIDEND","STOCK","Korr AG","US000TEST003","20.0000000000","","4.000000","","-1.10","EUR","","","","Cash Dividend","aaaa-0007","","","",""]'::jsonb,
        -- 9: unbekannter Typ -> unknown, Geld zaehlt trotzdem
        '["2026-09-08T10:00:00Z","2026-09-08","DEFAULT","CASH","SOMETHING_NEW","","","","","","-3.330000","","","EUR","","","","Neu","aaaa-0008","","","",""]'::jsonb,
        -- 10: Kartenzahlung, datetime am Vortag (UTC) -> date gewinnt
        '["2026-09-08T22:30:00Z","2026-09-09","DEFAULT","CASH","CARD_TRANSACTION","","","","","","-12.340000","","","EUR","","","","Baeckerei","aaaa-0009","Baeckerei Test","","",""]'::jsonb,
        -- 11: Leerzeile (Dateiende)
        '["","","","","","","","","","","","","","","","","","","","","","",""]'::jsonb,
        -- 12: Zins ohne Wertpapier
        '["2026-09-30T00:00:00Z","2026-09-30","DEFAULT","CASH","INTEREST_PAYMENT","","","","","","1.230000","","","EUR","","","","Interest","aaaa-0010","","","",""]'::jsonb,
        -- 13: gleich hohe Dividende derselben ISIN + Stueck ein Quartal frueher -> bleibt Dividende (nur EINE Zeile je Storno)
        '["2026-06-07T10:00:00Z","2026-06-07","DEFAULT","CASH","DIVIDEND","STOCK","Korr AG","US000TEST003","20.0000000000","","4.000000","","-1.00","EUR","","","","Cash Dividend","aaaa-0011","","","",""]'::jsonb);
    v_res JSONB;
    v_r   JSONB;
    v_acct INT;
BEGIN
    v_res := finance.fn_broker_csv_normalize(jsonb_build_object('header', v_hdr, 'rows', v_rows));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'profile' IS DISTINCT FROM 'trade_republic_v1' THEN
        RAISE EXCEPTION 'FAIL [N1 Profil erkannt]: %', v_res;
    END IF;
    IF jsonb_array_length(v_res->'rows') <> 11 THEN
        RAISE EXCEPTION 'FAIL [N2 Leerzeile uebersprungen, 11 Zeilen]: %', jsonb_array_length(v_res->'rows');
    END IF;
    RAISE NOTICE 'PASS [N1/N2 Profil + Zeilen]';

    -- die eine Adresse "welche Bank kann CSV": Trade Republic mit seinen Pflichtspalten
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_broker_csv_profiles()) pr
                   WHERE pr->>'key' = 'trade_republic_v1' AND pr->>'bank' = 'Trade Republic'
                     AND pr->'required' = '["datetime","category","type","amount","currency"]'::jsonb) THEN
        RAISE EXCEPTION 'FAIL [N0 fn_broker_csv_profiles]: %', finance.fn_broker_csv_profiles();
    END IF;

    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 2;
    IF v_r->>'kind' <> 'cash' OR (v_r->>'cash_amount')::numeric <> 120.00 THEN
        RAISE EXCEPTION 'FAIL [N3 Einzahlung netto 120.00]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 3;
    IF v_r->>'kind' <> 'buy' OR (v_r->>'cash_amount')::numeric <> -61.30 OR (v_r->>'shares')::numeric <> 3
       OR (v_r->>'gross')::numeric <> 60.30 OR (v_r->>'fee')::numeric <> 1.00 OR v_r->>'isin' <> 'IE00TEST0001'
       OR v_r->>'ext_ref' <> md5('aaaa-0002') THEN
        RAISE EXCEPTION 'FAIL [N4 Kauf]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 4;
    IF v_r->>'kind' <> 'sell' OR (v_r->>'cash_amount')::numeric <> 20.00 OR (v_r->>'shares')::numeric <> 1 THEN
        RAISE EXCEPTION 'FAIL [N5 Verkauf, Stueck als Betrag]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 5;
    IF v_r->>'kind' <> 'buy' OR v_r->>'isin' IS NOT NULL OR v_r->>'symbol' <> 'BTC' OR (v_r->>'cash_amount')::numeric <> -25.00 THEN
        RAISE EXCEPTION 'FAIL [N6 Krypto ohne ISIN]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 6;
    IF v_r->>'kind' <> 'dividend' OR (v_r->>'cash_amount')::numeric <> 7.50 THEN
        RAISE EXCEPTION 'FAIL [N7 Dividende netto]: %', v_r;
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_res->'rows') r
        WHERE (r->>'row_no')::int IN (7, 8) AND r->>'kind' = 'unknown' AND r->>'reason' = 'dividend_correction') <> 2 THEN
        RAISE EXCEPTION 'FAIL [N8 Dividenden-Korrektur beide unknown]: %', v_res->'rows';
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 9;
    IF v_r->>'kind' <> 'unknown' OR (v_r->>'cash_amount')::numeric <> -3.33 OR v_r->>'reason' <> 'unsupported_type' THEN
        RAISE EXCEPTION 'FAIL [N9 unbekannter Typ]: %', v_r;
    END IF;
    IF jsonb_array_length(v_res->'unknown_rows') <> 3
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'unknown_rows') u WHERE (u->>'row_no')::int = 9
                      AND u->>'type' = 'SOMETHING_NEW' AND (u->>'cash_amount')::numeric = -3.33) THEN
        RAISE EXCEPTION 'FAIL [N10 unknown_rows]: %', v_res->'unknown_rows';
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 10;
    IF (v_r->>'date')::date <> DATE '2026-09-09' OR v_r->>'counterparty' <> 'Baeckerei Test' THEN
        RAISE EXCEPTION 'FAIL [N11 date vor datetime]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 12;
    IF v_r->>'kind' <> 'interest' OR (v_r->>'cash_amount')::numeric <> 1.23 THEN
        RAISE EXCEPTION 'FAIL [N12 Zins]: %', v_r;
    END IF;
    IF v_res->'account_types' <> '["DEFAULT"]'::jsonb OR v_res->'currencies' <> '["EUR"]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [N13 Unterkonten/Waehrungen]: %', v_res;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 13;
    IF v_r->>'kind' <> 'dividend' OR (v_r->>'cash_amount')::numeric <> 3.00 THEN
        RAISE EXCEPTION 'FAIL [N8b fruehere gleich hohe Dividende bleibt Dividende]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [N3-N13 Zuordnung]';

    -- Semikolon-Variante liefert der Tokenizer gleich; Gross-/Kleinschreibung + BOM im Header egal
    v_res := finance.fn_broker_csv_normalize(jsonb_build_object(
        'header', '["﻿Datetime","Category","Type","Amount","Currency"]'::jsonb,
        'rows', '[["2026-09-02T08:00:00Z","CASH","TRANSFER_IN","5.00","EUR"]]'::jsonb));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR (v_res->'rows'->0->>'date')::date <> DATE '2026-09-02' OR (v_res->'rows'->0->>'cash_amount')::numeric <> 5 THEN
        RAISE EXCEPTION 'FAIL [N14 Mindest-Header, BOM, datetime-Datum]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [N14 Mindest-Header]';

    v_res := finance.fn_broker_csv_normalize(jsonb_build_object('header', '["Buchungstag","Betrag"]'::jsonb,
                 'rows', '[["01.09.2026","1,00"]]'::jsonb));
    IF v_res->>'code' IS DISTINCT FROM 'csv_profile_unknown' THEN
        RAISE EXCEPTION 'FAIL [N15 fremder Header]: %', v_res;
    END IF;
    v_res := finance.fn_broker_csv_normalize(jsonb_build_object('header', v_hdr,
                 'rows', jsonb_build_array(jsonb_set(v_rows->0, '{10}', '"1,234.50"'))));
    IF v_res->>'code' IS DISTINCT FROM 'csv_invalid' OR (v_res->>'row_no')::int <> 2 THEN
        RAISE EXCEPTION 'FAIL [N16 unlesbare Zahl]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [N15/N16 Ablehnungen]';

    -- Konto -> Profil (Bank-Name, sonst Konto-Name)
    v_acct := (finance.fn_create_account('{"name":"__t_csv_tr__","account_type":"cash","currency":"EUR","bank":"Trade Republic Bank"}'::jsonb)->>'account_id')::int;
    IF finance.fn_broker_csv_account_profile(v_acct) IS DISTINCT FROM 'trade_republic_v1' THEN
        RAISE EXCEPTION 'FAIL [N17 Konto-Profil per Bank]';
    END IF;
    v_acct := (finance.fn_create_account('{"name":"__t_csv_giro__","account_type":"cash","currency":"EUR","bank":"Testbank"}'::jsonb)->>'account_id')::int;
    IF finance.fn_broker_csv_account_profile(v_acct) IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [N18 andere Bank ohne Profil]';
    END IF;
    RAISE NOTICE 'PASS [N17/N18 Konto-Profil]';
END $$;
ROLLBACK;
