-- ============================================================
-- fn_bank_export_normalize_bitvavo (READ, IMMUTABLE) -- Profil bitvavo_v1 des Bank-Import-Moduls (Krypto-Boerse)
--   Fester Leser in Code, kein LLM. Aufruf nur ueber den Dispatcher fn_bank_export_normalize: Eingabe {columns
--   (Spaltenname -> Index), rows:[[text]] (Zeilen nach der Kopfzeile), header_row_no}.
--   Jede Zeile traegt currency 'EUR' (die Geld-Waehrung des Kontos, nie die Muenze aus Currency), sonst griffe
--   currency_mismatch in Konto-Waechter und Ersteinrichtung.
--   kind: cash (deposit/withdrawal in EUR, cash_amount = Amount - Fee), buy/sell (Muenze gegen EUR, Gebuehr in EUR;
--   die Gebuehr steckt im bezahlten Betrag: cash_amount = Received / Paid Amount, gross = |Paid| - Fee beim Kauf bzw.
--   Paid + Fee beim Verkauf, isin NULL, symbol = Muenze), reward (staking/fixed_staking mit Amount > 0: Stueck-Zugang
--   ohne Geld, cash_amount 0, price NULL), unknown (nie gebucht, Geld 0, reason: not_completed = Status weder
--   Completed noch Distributed; crypto_transfer = Ein-/Auszahlung einer Muenze; foreign_currency = Kauf/Verkauf mit
--   Quote, Zahlung oder Gebuehr nicht in EUR; unsupported_type = alles andere).
--   Paid mit mehr als 2 Nachkommastellen -> export_invalid (der gebuchte Betrag waere nicht centgenau).
--   sub_kind deposit|withdrawal (Geld-Zeilen ohne Gegen-IBAN): Stufe T paart sie mit dem Verrechnungskonto des Kontos;
--   transfer_fee = Gebuehr einer Auszahlung (Uebertrag ohne sie). Eine Einzahlung mit Gebuehr
--   bleibt ein Uebertrag ueber den Netto-Betrag und passt dann nicht zur Bank-Zeile: Rest, nie doppelt.
--   Rueckgabe: {ok:true, rows:[{row_no, date, kind, type, sub_kind, transfer_fee, cash_amount, isin, symbol, name, shares, price, gross, fee,
--   tax, currency, counterparty, counterparty_iban, purpose, ext_ref (md5 der Transaction ID), reason}],
--   unknown_rows:[{row_no, date, type, cash_amount, name, reason}], account_types[], currencies[]}
--   | {ok:false, code:'export_invalid', reason, row_no?}. row_no = Zeile in der Datei (Kopfzeile = header_row_no).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_normalize_bitvavo(p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_hrow    INT := COALESCE((p->>'header_row_no')::int, 1);
    v_idx     JSONB;
    v_row     JSONB;
    v_n       INT;
    v_out     JSONB;
    v_arr     JSONB[] := '{}';   -- Sammel-Array (PL/pgSQL haengt in place an; jsonb || je Zeile waere O(n^2))
    v_r       JSONB;
    v_d       DATE;
    v_amt     NUMERIC;
    v_paid    NUMERIC;
    v_fee     NUMERIC;
    v_typ     TEXT;
    v_cur     TEXT;
    v_stat    TEXT;
    v_kind    TEXT;
    v_reason  TEXT;
    v_cash    NUMERIC;
    v_gross   NUMERIC;
    v_raw     TEXT;
    v_col     TEXT;
BEGIN
    IF jsonb_typeof(p->'columns') IS DISTINCT FROM 'object' OR jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'reason', 'The file is not a readable table.');
    END IF;
    v_idx := p->'columns';

    FOR v_row, v_n IN SELECT e, (o)::int FROM jsonb_array_elements(p->'rows') WITH ORDINALITY AS x(e, o) LOOP
        CONTINUE WHEN jsonb_typeof(v_row) <> 'array'
            OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_row) c WHERE btrim(c) <> '');
        v_r := '{}'::jsonb;
        FOR v_col IN SELECT jsonb_object_keys(v_idx) LOOP
            v_raw := NULLIF(btrim(v_row->>((v_idx->>v_col)::int)), '');
            IF v_raw IS NOT NULL THEN v_r := v_r || jsonb_build_object(v_col, v_raw); END IF;
        END LOOP;
        FOREACH v_col IN ARRAY ARRAY['amount', 'quote price', 'received / paid amount', 'fee amount'] LOOP
            IF v_r ? v_col AND v_r->>v_col !~ '^[+-]?[0-9]+(\.[0-9]+)?$' THEN
                RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', v_n + v_hrow,
                    'reason', 'Row ' || (v_n + v_hrow) || ': "' || v_col || '" is not a number (' || (v_r->>v_col) || ').');
            END IF;
        END LOOP;
        v_raw := v_r->>'date';
        IF v_raw IS NULL OR NOT pg_input_is_valid(v_raw, 'date') THEN
            RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', v_n + v_hrow,
                'reason', 'Row ' || (v_n + v_hrow) || ' has no readable date.');
        END IF;
        v_d    := v_raw::date;
        v_amt  := (v_r->>'amount')::numeric;
        v_paid := (v_r->>'received / paid amount')::numeric;
        v_fee  := COALESCE((v_r->>'fee amount')::numeric, 0);
        v_typ  := lower(v_r->>'type');
        v_cur  := upper(v_r->>'currency');
        v_stat := lower(v_r->>'status');
        v_kind := 'unknown';
        v_reason := NULL;
        v_cash := 0;
        v_gross := NULL;

        IF v_stat IS DISTINCT FROM 'completed' AND v_stat IS DISTINCT FROM 'distributed' THEN
            v_reason := 'not_completed';
        ELSIF v_typ IN ('deposit', 'withdrawal') THEN
            IF v_cur = 'EUR' AND v_amt IS NOT NULL AND COALESCE(upper(v_r->>'fee currency'), 'EUR') = 'EUR' THEN
                v_kind := 'cash';
                v_cash := round(v_amt - v_fee, 2);
            ELSE
                v_reason := 'crypto_transfer';
            END IF;
        ELSIF v_typ IN ('buy', 'sell') THEN
            IF upper(v_r->>'quote currency') IS DISTINCT FROM 'EUR' OR upper(v_r->>'received / paid currency') IS DISTINCT FROM 'EUR'
               OR (v_fee <> 0 AND upper(v_r->>'fee currency') IS DISTINCT FROM 'EUR') OR v_cur = 'EUR' THEN
                v_reason := 'foreign_currency';
            ELSIF v_paid IS NULL OR v_amt IS NULL OR v_amt = 0 THEN
                v_reason := 'unsupported_type';
            ELSIF v_paid <> round(v_paid, 2) THEN
                RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', v_n + v_hrow,
                    'reason', 'Row ' || (v_n + v_hrow) || ': the paid amount has more than two decimals.');
            ELSE
                v_kind  := v_typ;
                v_cash  := v_paid;
                v_gross := CASE WHEN v_typ = 'buy' THEN abs(v_paid) - round(v_fee, 2) ELSE v_paid + round(v_fee, 2) END;
            END IF;
        ELSIF v_typ IN ('staking', 'fixed_staking') AND v_amt > 0 AND v_cur <> 'EUR' THEN
            v_kind := 'reward';
        ELSE
            v_reason := 'unsupported_type';
        END IF;

        v_arr := v_arr || jsonb_build_object(
            'row_no', v_n + v_hrow, 'date', v_d, 'kind', v_kind, 'type', v_typ,
            'sub_kind', CASE WHEN v_kind = 'cash' THEN v_typ END,
            -- Auszahlung mit Gebuehr (Muster Bondora): Uebertrag = Abgang - Gebuehr, die Gebuehr bucht die Prepare eigens
            'transfer_fee', CASE WHEN v_kind = 'cash' AND v_typ = 'withdrawal' AND v_fee > 0 THEN round(v_fee, 2) END,
            'cash_amount', v_cash,
            'isin', NULL, 'symbol', CASE WHEN v_cur <> 'EUR' THEN v_cur END,
            'name', CASE WHEN v_cur <> 'EUR' THEN v_cur END,
            'shares', CASE WHEN v_kind IN ('buy', 'sell', 'reward') THEN abs(v_amt) END,
            'price', CASE WHEN v_kind IN ('buy', 'sell') THEN (v_r->>'quote price')::numeric END,
            'gross', v_gross, 'fee', CASE WHEN v_kind IN ('buy', 'sell') THEN round(v_fee, 2) END, 'tax', 0,
            'currency', 'EUR', 'counterparty', NULL, 'counterparty_iban', NULL,
            'purpose', v_typ || CASE WHEN v_cur IS NOT NULL THEN ' ' || v_cur ELSE '' END,
            'ext_ref', CASE WHEN v_r ? 'transaction id' THEN md5(v_r->>'transaction id') END,
            'reason', v_reason);
    END LOOP;

    v_out := to_jsonb(v_arr);
    RETURN jsonb_build_object('ok', true, 'rows', v_out,
        'unknown_rows', (SELECT COALESCE(jsonb_agg(jsonb_build_object('row_no', r->'row_no', 'date', r->'date',
                             'type', r->'type', 'cash_amount', r->'cash_amount', 'name', COALESCE(r->>'name', r->>'purpose'),
                             'reason', r->'reason') ORDER BY (r->>'row_no')::int), '[]'::jsonb)
                         FROM jsonb_array_elements(v_out) r WHERE r->>'kind' = 'unknown'),
        'account_types', '[]'::jsonb,
        'currencies', CASE WHEN jsonb_array_length(v_out) > 0 THEN '["EUR"]'::jsonb ELSE '[]'::jsonb END);
END;
$$;
