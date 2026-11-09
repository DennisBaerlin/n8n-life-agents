-- ============================================================
-- test_fn_bank_export_normalize_no_amount -- Trade-Republic-Zeilen ohne Betrag (Bank-Import-Modul)
--   Eigenschaft: Eine Zeile ohne Betrag (Kapitalmassnahme, Gratis-Einbuchung, Kauf ohne Geldfluss) lehnt den Export nicht
--   ab; sie wird unknown (reason no_cash_amount), bucht kein Geld, bleibt in unknown_rows und steht auf der Karte
--   (export_unknown). Eine Zeile ohne Datum lehnt weiter ab, eine Zeile mit Betrag aber ohne Waehrung bleibt buchbar.
--   Werte frei erfunden.
-- ============================================================
BEGIN;
DO $$
DECLARE
    T DATE := core.fn_today();
    v_hdr JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]'::jsonb;
    v_rows JSONB;
    v_res JSONB;
    v_prep JSONB;
    v_r JSONB;
    v_ok BOOLEAN;
BEGIN
    -- Spalten: datetime,date,account_type,category,type,asset_class,name,symbol,shares,price,amount,fee,tax,currency,...
    v_rows := jsonb_build_array(
        jsonb_build_array(T - 6 || 'T08:00:00Z', (T - 6)::text, 'DEFAULT', 'CORPORATE_ACTION', 'MERGER', 'STOCK', 'Alt AG', 'DE000TEST0010', '2', '', '', '', '', '', '', '', '', 'Merger', 'na-0001', '', '', '', ''),
        jsonb_build_array(T - 5 || 'T08:00:00Z', (T - 5)::text, 'DEFAULT', 'CORPORATE_ACTION', 'SPIN_OFF', 'STOCK', 'Abspalt AG', 'DE000TEST0011', '1', '', '', '', '', '', '', '', '', 'Spin-off', 'na-0002', '', '', '', ''),
        jsonb_build_array(T - 4 || 'T08:00:00Z', (T - 4)::text, 'DEFAULT', 'DELIVERY', 'FREE_RECEIPT', 'STOCK', 'Geschenk AG', 'DE000TEST0012', '3', '', '', '', '', '', '', '', '', 'Free receipt', 'na-0003', '', '', '', ''),
        jsonb_build_array(T - 3 || 'T08:00:00Z', (T - 3)::text, 'DEFAULT', 'TRADING', 'BUY', 'FUND', 'Test ETF', 'IE00TEST0013', '4', '25.00', '', '', '', '', '', '', '', 'Buy without amount', 'na-0004', '', '', '', ''),
        -- fuenfte Art: Betrag, aber keine Waehrung -> bleibt buchbar (cash)
        jsonb_build_array(T - 2 || 'T08:00:00Z', (T - 2)::text, 'DEFAULT', 'CASH', 'CARD_TRANSACTION', '', '', '', '', '', '-5.00', '', '', '', '', '', '', 'Kiosk', 'na-0005', 'Kiosk Test', '', '', ''));

    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [A1 Export wird gelesen]: %', v_res;
    END IF;
    IF jsonb_array_length(v_res->'unknown_rows') <> 4
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'unknown_rows') u
                  WHERE u->>'reason' IS DISTINCT FROM 'no_cash_amount' OR (u->>'cash_amount')::numeric <> 0) THEN
        RAISE EXCEPTION 'FAIL [A2 vier unknown, no_cash_amount, Geld 0]: %', v_res->'unknown_rows';
    END IF;
    -- der Kauf ohne Betrag wird NICHT als Kauf gebucht (kind unknown, nie buy)
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 5;
    IF v_r->>'kind' <> 'unknown' OR v_r->>'reason' <> 'no_cash_amount' THEN
        RAISE EXCEPTION 'FAIL [A3 Kauf ohne Betrag = unknown]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [A1-A3 vier Zeilen ohne Betrag]';

    -- fuenfte Art: Betrag ohne Waehrung
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 6;
    IF v_r->>'kind' <> 'cash' OR (v_r->>'cash_amount')::numeric <> -5 OR v_r->'currency' <> 'null'::jsonb
       OR v_res->'currencies' <> '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [A4 Betrag ohne Waehrung]: % / %', v_r, v_res->'currencies';
    END IF;
    RAISE NOTICE 'PASS [A4 Betrag ohne Waehrung]';

    -- Zeile ohne Datum lehnt weiter ab und nennt Zeile + Grund
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows',
                 jsonb_build_array(v_hdr, jsonb_set(jsonb_set(v_rows->0, '{0}', '""'), '{1}', '""'))));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 2 OR v_res->>'reason' NOT LIKE 'Row 2%date%' THEN
        RAISE EXCEPTION 'FAIL [A5 ohne Datum]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [A5 Datum bleibt Pflicht]';

    -- durch die Vorschau: nichts gebucht, die Zeilen stehen auf der Karte, der Rest stimmt
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_na__', 'account_type', 'cash', 'currency', 'EUR',
                'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text));
    v_prep := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'account_name', '__t_na__', 'closing_balance', '995',
                'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows)));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [A6 Vorschau ok]: %', v_prep;
    END IF;
    IF jsonb_array_length(v_prep->'export_unknown') <> 4 OR jsonb_array_length(COALESCE(v_prep->'trades', '[]'::jsonb)) <> 0
       OR jsonb_array_length(COALESCE(v_prep->'trades_blocked', '[]'::jsonb)) <> 0 THEN
        RAISE EXCEPTION 'FAIL [A7 vier Zeilen gemeldet, kein Handel]: %', v_prep;
    END IF;
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_export_unknown')
      INTO v_ok;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FAIL [A8 Karte nennt unbekannte Zeilen]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [A6-A8 Vorschau]';

    -- Buchen: Konto landet auf dem App-Stand, kein Depot/keine Position aus den Zeilen ohne Betrag
    v_res := finance.fn_apply_bank_statement(jsonb_build_object('source', 'file', 'account_name', '__t_na__', 'closing_balance', '995',
                'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows), 'fingerprint', v_prep->>'fingerprint'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR finance.fn_get_balance_as_of((SELECT id FROM finance.accounts WHERE name = '__t_na__'), T) <> 995
       OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE isin IN ('DE000TEST0010', 'DE000TEST0011', 'DE000TEST0012', 'IE00TEST0013')) THEN
        RAISE EXCEPTION 'FAIL [A9 Buchung ohne Geld/Position aus Nullzeilen]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [A9 Buchung]';
END $$;
ROLLBACK;
