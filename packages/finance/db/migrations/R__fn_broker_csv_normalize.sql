-- ============================================================
-- fn_broker_csv_normalize (READ, IMMUTABLE) -- Broker-CSV-Export -> normierte Zeilen (Broker-CSV Paket B)
--   Fester Leser in Code, kein LLM (die Datei geht nicht an Anthropic). Eingabe = Ausgabe des generischen Tokenizers
--   im Workflow: {header:[text], rows:[[text]]} (RFC 4180, Bedeutung kennt der Tokenizer nicht).
--   Profil per Header-Signatur aus fn_broker_csv_profiles (alle required-Spalten vorhanden). Profil trade_republic_v1
--   (Zuordnung nach Portfolio Performance TradeRepublicCSVExtractor): Datum = Spalte date (Buchungstag), sonst die
--   ersten 10 Zeichen von datetime; cash_amount = amount + fee + tax (alle signiert, gerundet auf Cent) = Wirkung aufs
--   Cashkonto; isin = symbol (bei asset_class CRYPTO NULL, symbol bleibt der Ticker).
--   kind: buy/sell (TRADING BUY/SELL mit Stueck), dividend (DIVIDEND/DISTRIBUTION/DIVIDEND_EQUIVALENT_PAYMENT,
--   INTEREST_PAYMENT mit Wertpapier), interest (INTEREST_PAYMENT ohne Wertpapier), tax (TAX, TAX_OPTIMIZATION,
--   PRE_DETERMINED_TAX_BASE, SEC_ACCOUNT, EARNINGS mit Abfluss), fee (FEE, CARD_ORDERING_FEE), corporate
--   (CORPORATE_ACTION REDEMPTION/FINAL_MATURITY/WARRANT_EXERCISE: Info, das Geld kommt als eigene CASH-Zeile),
--   cash (Ein-/Auszahlungen, Karte, Ueberweisungen), unknown (alles andere, nie still verworfen).
--   DIVIDENDEN-KORREKTUR (PP-Forum): eine Dividenden-Zeile mit negativem amount storniert eine fruehere; sie und die
--   gleich hohe positive Zeile derselben ISIN + Stueckzahl im Export werden unknown (reason dividend_correction) ->
--   nie automatisch gebucht, die Karte nennt sie. Das Geld zaehlt trotzdem (cash_amount bleibt).
--   RUECKGABE: {ok:true, profile, rows:[{row_no, date, kind, category, type, cash_amount, isin, symbol, name,
--   asset_class, shares (Betrag), price, gross (|amount|), fee (Betrag), tax (signiert), currency, account_type,
--   counterparty, counterparty_iban, purpose, ext_ref (md5 der transaction_id), reason}], unknown_rows:[{row_no, date,
--   category, type, cash_amount, name, reason}], account_types[], currencies[]}
--   | {ok:false, code:'csv_profile_unknown'|'csv_invalid', reason, row_no?}.
--   row_no = Zeile in der Datei (Header = 1).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_broker_csv_normalize(p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_hdr     JSONB;
    v_prof    JSONB;
    v_idx     JSONB := '{}'::jsonb;
    v_row     JSONB;
    v_n       INT;
    v_out     JSONB := '[]'::jsonb;
    v_r       JSONB;
    v_d       DATE;
    v_amt     NUMERIC;
    v_fee     NUMERIC;
    v_tax     NUMERIC;
    v_sh      NUMERIC;
    v_px      NUMERIC;
    v_cat     TEXT;
    v_typ     TEXT;
    v_kind    TEXT;
    v_cls     TEXT;
    v_sym     TEXT;
    v_raw     TEXT;
    v_col     TEXT;
    v_reason  TEXT;
BEGIN
    IF jsonb_typeof(p->'header') IS DISTINCT FROM 'array' OR jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'csv_invalid', 'reason', 'The file is not a readable CSV table.');
    END IF;
    SELECT jsonb_agg(lower(btrim(h, E' \t\r\n"﻿')) ORDER BY o) INTO v_hdr
    FROM jsonb_array_elements_text(p->'header') WITH ORDINALITY AS x(h, o);
    SELECT jsonb_object_agg(h, o - 1) INTO v_idx
    FROM (SELECT DISTINCT ON (h) h, o FROM jsonb_array_elements_text(v_hdr) WITH ORDINALITY AS x(h, o) ORDER BY h, o) s;

    SELECT pr INTO v_prof FROM jsonb_array_elements(finance.fn_broker_csv_profiles()) pr
    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(pr->'required') c WHERE NOT (v_idx ? c))
    LIMIT 1;
    IF v_prof IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'csv_profile_unknown',
            'reason', 'This CSV export is not from a supported bank (known: '
                   || (SELECT string_agg(pr->>'bank', ', ') FROM jsonb_array_elements(finance.fn_broker_csv_profiles()) pr)
                   || ') or its columns changed.');
    END IF;

    FOR v_row, v_n IN SELECT e, (o)::int FROM jsonb_array_elements(p->'rows') WITH ORDINALITY AS x(e, o) LOOP
        -- komplett leere Zeile (Dateiende, Leerzeile) ueberspringen
        CONTINUE WHEN jsonb_typeof(v_row) <> 'array'
            OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_row) c WHERE btrim(c) <> '');
        v_r := '{}'::jsonb;
        FOR v_col IN SELECT jsonb_object_keys(v_idx) LOOP
            v_raw := NULLIF(btrim(v_row->>((v_idx->>v_col)::int)), '');
            IF v_raw IS NOT NULL THEN v_r := v_r || jsonb_build_object(v_col, v_raw); END IF;
        END LOOP;
        -- Zahlen strikt (Punkt als Dezimaltrenner, keine Tausender): eine unlesbare Zahl bricht laut ab
        FOREACH v_col IN ARRAY ARRAY['amount', 'fee', 'tax', 'shares', 'price'] LOOP
            IF v_r ? v_col AND NOT pg_input_is_valid(v_r->>v_col, 'numeric') THEN
                RETURN jsonb_build_object('ok', false, 'code', 'csv_invalid', 'row_no', v_n + 1,
                    'reason', 'Row ' || (v_n + 1) || ': "' || v_col || '" is not a number (' || (v_r->>v_col) || ').');
            END IF;
        END LOOP;
        v_raw := COALESCE(v_r->>'date', left(v_r->>'datetime', 10));
        IF v_raw IS NULL OR NOT pg_input_is_valid(v_raw, 'date') OR NOT (v_r ? 'amount') THEN
            RETURN jsonb_build_object('ok', false, 'code', 'csv_invalid', 'row_no', v_n + 1,
                'reason', 'Row ' || (v_n + 1) || ' has no readable date or amount.');
        END IF;
        v_d   := v_raw::date;
        v_amt := (v_r->>'amount')::numeric;
        v_fee := COALESCE((v_r->>'fee')::numeric, 0);
        v_tax := COALESCE((v_r->>'tax')::numeric, 0);
        v_sh  := abs((v_r->>'shares')::numeric);
        v_px  := (v_r->>'price')::numeric;
        v_cat := upper(v_r->>'category');
        v_typ := upper(v_r->>'type');
        v_cls := upper(v_r->>'asset_class');
        v_sym := v_r->>'symbol';
        v_reason := NULL;

        v_kind := CASE
            WHEN v_cat = 'TRADING' AND v_typ IN ('BUY', 'SELL') AND v_sh > 0 AND v_sym IS NOT NULL THEN lower(v_typ)
            WHEN v_cat = 'CASH' AND v_typ IN ('DIVIDEND', 'DISTRIBUTION', 'DIVIDEND_EQUIVALENT_PAYMENT') AND v_sym IS NOT NULL
                 THEN 'dividend'
            WHEN v_cat = 'CASH' AND v_typ = 'INTEREST_PAYMENT' THEN CASE WHEN v_sym IS NOT NULL THEN 'dividend' ELSE 'interest' END
            WHEN v_cat = 'CASH' AND (v_typ IN ('TAX', 'TAX_OPTIMIZATION', 'PRE_DETERMINED_TAX_BASE', 'SEC_ACCOUNT')
                                     OR (v_typ = 'EARNINGS' AND v_amt + v_fee + v_tax < 0)) THEN 'tax'
            WHEN v_cat = 'CASH' AND v_typ IN ('FEE', 'CARD_ORDERING_FEE') THEN 'fee'
            WHEN v_cat = 'CORPORATE_ACTION' AND v_typ IN ('REDEMPTION', 'FINAL_MATURITY', 'WARRANT_EXERCISE') THEN 'corporate'
            WHEN v_cat = 'CASH' AND v_typ IN (
                 'CUSTOMER_INBOUND', 'CUSTOMER_INPAYMENT', 'TRANSFER_INBOUND', 'TRANSFER_INSTANT_INBOUND',
                 'CUSTOMER_OUTBOUND_REQUEST', 'GIFT', 'ADDITIONAL_INCOME', 'BENEFITS_SAVEBACK', 'BONUS', 'CARD_TRANSACTION',
                 'CARD_TRANSACTION_INTERNATIONAL', 'CARD_TRANSACTION_REFUND', 'CARD_TRANSACTION_REFUND_REVERSAL',
                 'COMPENSATION', 'CUSTOMER_INPAYMENT_REVERSAL', 'GENERAL_INBOUND', 'KINDERGELD_BONUS', 'MANUAL',
                 'MANUAL_CASH_TRANSFER', 'PAYMENT', 'REFERRAL', 'STOCKPERK', 'TRANSFER_DIRECT_DEBIT_INBOUND', 'TRANSFER_IN',
                 'TRANSFER_INSTANT_OUTBOUND', 'TRANSFER_OUT', 'TRANSFER_OUTBOUND', 'VIBAN_TRANSFER_INBOUND',
                 'VIBAN_TRANSFER_OUTBOUND') THEN 'cash'
            ELSE 'unknown' END;
        IF v_kind = 'unknown' THEN v_reason := 'unsupported_type'; END IF;
        IF v_kind = 'dividend' AND v_amt < 0 THEN v_kind := 'unknown'; v_reason := 'dividend_correction'; END IF;

        v_out := v_out || jsonb_build_object(
            'row_no', v_n + 1, 'date', v_d, 'kind', v_kind, 'category', v_cat, 'type', v_typ,
            'cash_amount', round(v_amt + v_fee + v_tax, 2),
            'isin', CASE WHEN v_cls = 'CRYPTO' THEN NULL ELSE upper(v_sym) END,
            'symbol', v_sym, 'name', v_r->>'name', 'asset_class', v_cls,
            'shares', CASE WHEN v_sh > 0 THEN v_sh END, 'price', v_px, 'gross', abs(v_amt), 'fee', abs(v_fee), 'tax', v_tax,
            'currency', upper(v_r->>'currency'), 'account_type', upper(v_r->>'account_type'),
            'counterparty', v_r->>'counterparty_name', 'counterparty_iban', v_r->>'counterparty_iban',
            'purpose', NULLIF(concat_ws(' ', v_r->>'description', v_r->>'payment_reference'), ''),
            'ext_ref', CASE WHEN v_r ? 'transaction_id' THEN md5(v_r->>'transaction_id') END,
            'reason', v_reason);
    END LOOP;

    -- Dividenden-Korrektur: die gleich hohe positive Zeile derselben ISIN + Stueck wird ebenfalls nicht gebucht
    SELECT COALESCE(jsonb_agg(CASE
               WHEN r->>'kind' = 'dividend' AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(v_out) c
                    WHERE c->>'reason' = 'dividend_correction' AND c->>'isin' = r->>'isin'
                      AND (c->>'shares')::numeric IS NOT DISTINCT FROM (r->>'shares')::numeric
                      AND (c->>'gross')::numeric = (r->>'gross')::numeric)
               THEN r || jsonb_build_object('kind', 'unknown', 'reason', 'dividend_correction')
               ELSE r END ORDER BY (r->>'row_no')::int), '[]'::jsonb)
    INTO v_out FROM jsonb_array_elements(v_out) r;

    RETURN jsonb_build_object('ok', true, 'profile', v_prof->>'key', 'rows', v_out,
        'unknown_rows', (SELECT COALESCE(jsonb_agg(jsonb_build_object('row_no', r->'row_no', 'date', r->'date',
                             'category', r->'category', 'type', r->'type', 'cash_amount', r->'cash_amount',
                             'name', COALESCE(r->'name', r->'purpose'), 'reason', r->'reason') ORDER BY (r->>'row_no')::int), '[]'::jsonb)
                         FROM jsonb_array_elements(v_out) r WHERE r->>'kind' = 'unknown'),
        'account_types', (SELECT COALESCE(jsonb_agg(DISTINCT r->>'account_type'), '[]'::jsonb)
                          FROM jsonb_array_elements(v_out) r WHERE r->>'account_type' IS NOT NULL),
        'currencies', (SELECT COALESCE(jsonb_agg(DISTINCT r->>'currency'), '[]'::jsonb)
                       FROM jsonb_array_elements(v_out) r WHERE r->>'currency' IS NOT NULL));
END;
$$;
