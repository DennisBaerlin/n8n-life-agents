-- ============================================================
-- test_fn_bank_export_normalize_bitvavo -- Golden-File Profil bitvavo_v1 (Bank-Import-Modul)
--   finance.fn_bank_export_normalize (Dispatcher) -> fn_bank_export_normalize_bitvavo / fn_bank_export_profiles /
--   fn_bank_export_account_profile. Fixture = Bitvavo-Spaltenform (Transaktions-Export), Werte frei erfunden.
--   Deckt: Profil-Erkennung + Registry, jede Zeile currency EUR (nie die Muenze), Ein-/Auszahlung EUR -> cash
--   (Amount - Fee), Kauf/Verkauf (Gebuehr im bezahlten Betrag: gross = |Paid| - Fee bzw. Paid + Fee, cash_amount = Paid,
--   isin NULL, symbol = Muenze), Staking/Fixed Staking -> reward (Stueck > 0, Geld 0), Gruende crypto_transfer /
--   not_completed / foreign_currency / unsupported_type (nie gebucht, unknown_rows), Paid mit 3 Nachkommastellen ->
--   export_invalid, ext_ref 32-Hex eindeutig, Konto -> Profil ohne Kollision mit TR/N26/Bondora.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_hdr JSONB := '["Timezone","Date","Time","Type","Currency","Amount","Quote Currency","Quote Price","Received / Paid Currency","Received / Paid Amount","Fee currency","Fee amount","Status","Transaction ID","Address"]';
    v_rows JSONB := jsonb_build_array(
        -- 2: Einzahlung EUR
        '["Europe/Amsterdam","2026-08-01","09:00:00","deposit","EUR","500.00","","","","","EUR","0.00","Completed","tx-bv-0002",""]'::jsonb,
        -- 3: Kauf BTC, Gebuehr steckt im bezahlten Betrag: 0.001 x 60000 + 0.15 = 60.15
        '["Europe/Amsterdam","2026-08-02","10:00:00","buy","BTC","0.00100000","EUR","60000.00","EUR","-60.15","EUR","0.15","Completed","tx-bv-0003",""]'::jsonb,
        -- 4: Kauf einer Kleinst-Muenze, 3 000 000 Stueck fuer 25.00 inkl. 0.06 Gebuehr
        '["Europe/Amsterdam","2026-08-02","11:00:00","buy","XMEME","3000000","EUR","0.00000831","EUR","-25.00","EUR","0.06","Completed","tx-bv-0004",""]'::jsonb,
        -- 5 + 6: Staking-Ertraege ohne Euro-Betrag
        '["Europe/Amsterdam","2026-08-03","02:00:00","staking","ETH","0.00012345","","","","","","","Distributed","tx-bv-0005",""]'::jsonb,
        '["Europe/Amsterdam","2026-08-04","02:00:00","fixed_staking","ETH","0.00020000","","","","","","","Completed","tx-bv-0006",""]'::jsonb,
        -- 7: Staking noch nicht verteilt
        '["Europe/Amsterdam","2026-08-05","02:00:00","staking","ETH","0.00010000","","","","","","","Pending","tx-bv-0007",""]'::jsonb,
        -- 8: Krypto-Einzahlung von aussen (Muenze statt EUR)
        '["Europe/Amsterdam","2026-08-06","12:00:00","deposit","BTC","0.00500000","","","","","BTC","0.00000000","Completed","tx-bv-0008","bc1qtestaddress0000"]'::jsonb,
        -- 9: Kauf mit Gebuehr in der Muenze
        '["Europe/Amsterdam","2026-08-07","10:00:00","buy","ETH","0.01000000","EUR","3000.00","EUR","-30.00","ETH","0.00002000","Completed","tx-bv-0009",""]'::jsonb,
        -- 10: Verkauf BTC, Gebuehr vom Erloes abgezogen: 0.0005 x 63960 - 0.08 = 31.90
        '["Europe/Amsterdam","2026-08-08","10:00:00","sell","BTC","-0.00050000","EUR","63960.00","EUR","31.90","EUR","0.08","Completed","tx-bv-0010",""]'::jsonb,
        -- 11: Auszahlung EUR
        '["Europe/Amsterdam","2026-08-09","10:00:00","withdrawal","EUR","-100.00","","","","","EUR","0.00","Completed","tx-bv-0011",""]'::jsonb,
        -- 12: unbekannte Art
        '["Europe/Amsterdam","2026-08-10","10:00:00","affiliate","EUR","1.00","","","","","","","Completed","tx-bv-0012",""]'::jsonb);
    v_res  JSONB;
    v_r    JSONB;
    v_acct INT;
BEGIN
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'profile' IS DISTINCT FROM 'bitvavo_v1'
       OR (v_res->>'printed_balance')::boolean THEN
        RAISE EXCEPTION 'FAIL [V1 Profil erkannt]: %', v_res;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr
                   WHERE pr->>'key' = 'bitvavo_v1' AND pr->>'bank' = 'Bitvavo' AND NOT (pr->>'printed_balance')::boolean
                     AND (pr->>'is_broker')::boolean AND pr->>'default_account_type' = 'cash'
                     AND pr->>'interest_source' = 'none' AND pr ? 'counterparty_pattern') THEN
        RAISE EXCEPTION 'FAIL [V0 Registry]: %', finance.fn_bank_export_profiles();
    END IF;
    IF jsonb_array_length(v_res->'rows') <> 11 OR v_res->'currencies' <> '["EUR"]'::jsonb
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'rows') r WHERE r->>'currency' IS DISTINCT FROM 'EUR') THEN
        RAISE EXCEPTION 'FAIL [V2 11 Zeilen, jede in EUR]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [V0-V2 Profil + Zeilen]';

    -- Geld-Zeilen
    IF (SELECT string_agg((r->>'row_no') || ':' || (r->>'kind') || ':' || ((r->>'cash_amount')::numeric)::text, ',' ORDER BY (r->>'row_no')::int)
        FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int IN (2, 11))
       IS DISTINCT FROM '2:cash:500.00,11:cash:-100.00' THEN
        RAISE EXCEPTION 'FAIL [V3 Ein-/Auszahlung]: %', v_res->'rows';
    END IF;
    -- Kauf: Kurswert = bezahlt - Gebuehr, Betrag = bezahlt
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 3;
    IF v_r->>'kind' <> 'buy' OR v_r->>'isin' IS NOT NULL OR v_r->>'symbol' <> 'BTC' OR (v_r->>'shares')::numeric <> 0.001
       OR (v_r->>'fee')::numeric <> 0.15 OR (v_r->>'gross')::numeric <> 60.00 OR (v_r->>'cash_amount')::numeric <> -60.15
       OR (v_r->>'date')::date <> DATE '2026-08-02' THEN
        RAISE EXCEPTION 'FAIL [V4 Kauf BTC]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 4;
    IF v_r->>'kind' <> 'buy' OR v_r->>'symbol' <> 'XMEME' OR (v_r->>'shares')::numeric <> 3000000
       OR (v_r->>'fee')::numeric <> 0.06 OR (v_r->>'gross')::numeric <> 24.94 OR (v_r->>'cash_amount')::numeric <> -25.00 THEN
        RAISE EXCEPTION 'FAIL [V5 Kauf Kleinst-Muenze]: %', v_r;
    END IF;
    -- Verkauf: Kurswert = erhalten + Gebuehr, Stueck als Betrag
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 10;
    IF v_r->>'kind' <> 'sell' OR v_r->>'symbol' <> 'BTC' OR (v_r->>'shares')::numeric <> 0.0005
       OR (v_r->>'fee')::numeric <> 0.08 OR (v_r->>'gross')::numeric <> 31.98 OR (v_r->>'cash_amount')::numeric <> 31.90 THEN
        RAISE EXCEPTION 'FAIL [V6 Verkauf]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [V3-V6 Geld, Kauf, Verkauf]';

    -- Staking -> reward
    IF (SELECT string_agg((r->>'row_no') || ':' || (r->>'kind') || ':' || (r->>'symbol') || ':' || ((r->>'shares')::numeric)::text
                          || ':' || ((r->>'cash_amount')::numeric)::text, ',' ORDER BY (r->>'row_no')::int)
        FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int IN (5, 6))
       IS DISTINCT FROM '5:reward:ETH:0.00012345:0,6:reward:ETH:0.00020000:0' THEN
        RAISE EXCEPTION 'FAIL [V7 Staking -> reward]: %', v_res->'rows';
    END IF;
    RAISE NOTICE 'PASS [V7 Staking]';

    -- nie gebucht: Gruende als Daten, Geld 0
    IF (SELECT string_agg((r->>'row_no') || ':' || (r->>'kind') || ':' || (r->>'reason') || ':' || ((r->>'cash_amount')::numeric)::text,
                          ',' ORDER BY (r->>'row_no')::int)
        FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int IN (7, 8, 9, 12))
       IS DISTINCT FROM '7:unknown:not_completed:0,8:unknown:crypto_transfer:0,9:unknown:foreign_currency:0,12:unknown:unsupported_type:0' THEN
        RAISE EXCEPTION 'FAIL [V8 Gruende]: %', v_res->'rows';
    END IF;
    IF jsonb_array_length(v_res->'unknown_rows') <> 4 THEN
        RAISE EXCEPTION 'FAIL [V9 unknown_rows]: %', v_res->'unknown_rows';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'rows') r WHERE r->>'ext_ref' IS NULL OR r->>'ext_ref' !~ '^[0-9a-f]{32}$')
       OR (SELECT count(DISTINCT r->>'ext_ref') FROM jsonb_array_elements(v_res->'rows') r) <> 11 THEN
        RAISE EXCEPTION 'FAIL [V10 ext_ref 32-Hex + eindeutig]: %', v_res->'rows';
    END IF;
    RAISE NOTICE 'PASS [V8-V10 nie gebucht, ext_ref]';

    -- Betrag mit 3 Nachkommastellen -> export_invalid mit Zeile
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
        '["Europe/Amsterdam","2026-08-02","10:00:00","buy","BTC","0.00100000","EUR","60000.00","EUR","-60.155","EUR","0.155","Completed","tx-bv-0099",""]'::jsonb)));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FAIL [V11 Paid mit 3 Nachkommastellen]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [V11 export_invalid]';

    -- Konto -> Profil, keine Kollision mit den anderen Profilen
    v_acct := (finance.fn_create_account('{"name":"__t_bv_a__","account_type":"cash","currency":"EUR","bank":"Bitvavo"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'bitvavo_v1' THEN RAISE EXCEPTION 'FAIL [V12 Bank Bitvavo]'; END IF;
    v_acct := (finance.fn_create_account('{"name":"__t_bv_b__","account_type":"cash","currency":"EUR","bank":"Trade Republic"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'trade_republic_v1' THEN RAISE EXCEPTION 'FAIL [V13 TR bleibt TR]'; END IF;
    v_acct := (finance.fn_create_account('{"name":"__t_bv_c__","account_type":"cash","currency":"EUR","bank":"N26"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'n26_v1' THEN RAISE EXCEPTION 'FAIL [V14 N26 bleibt N26]'; END IF;
    v_acct := (finance.fn_create_account('{"name":"__t_bv_d__","account_type":"p2p","currency":"EUR","bank":"Bondora"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'bondora_go_grow_v1' THEN RAISE EXCEPTION 'FAIL [V15 Bondora bleibt Bondora]'; END IF;
    RAISE NOTICE 'PASS [V12-V15 Konto-Profil]';
END $$;
ROLLBACK;
