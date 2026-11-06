-- ============================================================
-- fn_bank_export_normalize_n26 (READ, IMMUTABLE) -- Profil n26_v1 des Bank-Import-Moduls
--   Fester Leser in Code, kein LLM (die Datei geht nicht an Anthropic). Aufruf NUR ueber den Dispatcher
--   fn_bank_export_normalize: Eingabe {columns (Spaltenname -> Index), rows (nach der Kopfzeile), header_row_no}.
--   N26-CSV-Export (Format seit 2025): Booking Date | Value Date | Partner Name | Partner Iban | Type |
--   Payment Reference | Account Name | Amount (EUR) | Original Amount | Original Currency | Exchange Rate.
--   Kein Saldo in der Datei (Owner-Saldo Pflicht).
--   date = Booking Date (Buchungstag, er zaehlt fuer den App-Stand; Muster beangulp), strikt YYYY-MM-DD, Pflicht;
--   cash_amount = Amount (EUR) auf Cent, strikt -?Ziffern(.Ziffern) (wirkt aufs Konto; Fremdwaehrungsspalten werden
--   weder gelesen noch geprueft); counterparty_iban ohne Leerzeichen, gross; account_type = Account Name (N26-Space;
--   mehrere -> Prepare-Waechter multiple_sub_accounts). kind: presentment (Karte), debit transfer, credit transfer,
--   direct debit, moneybeam -> cash; alles andere -> unknown (reason unsupported_type, nie still verworfen).
--   ext_ref (N26 hat keine Transaktions-ID) = md5 ueber [Buchungstag, Betrag auf Cent, IBAN, Partner, Referenz] +
--   laufende Nummer gleicher Zeilen in Dateifolge: bewusst ohne Space-Name, Valuta, Typ und Fremdwaehrung, damit ein
--   umbenannter Space oder "-30" statt "-30.00" eine schon gesehene Zeile nie als verspaetet doppelt zaehlen laesst.
--   RUECKGABE: {ok:true, rows:[{row_no, date, kind, type, cash_amount, counterparty, counterparty_iban, purpose, name,
--   account_type, ext_ref, reason}], unknown_rows:[{row_no, date, type, cash_amount, name, reason}], account_types[],
--   currencies (["EUR"])} | {ok:false, code:'export_invalid', reason, row_no?}.
--   row_no = Zeile in der Datei (Kopfzeile = header_row_no).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_normalize_n26(p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_hrow    INT := COALESCE((p->>'header_row_no')::int, 1);
    v_idx     JSONB := p->'columns';
    v_row     JSONB;
    v_n       INT;
    v_arr     JSONB[] := '{}';   -- Sammel-Array (PL/pgSQL haengt in place an; jsonb || je Zeile waere O(n^2))
    v_out     JSONB;
    v_bd      TEXT;
    v_raw     TEXT;
    v_amt     NUMERIC;
    v_iban    TEXT;
    v_partner TEXT;
    v_ref     TEXT;
    v_typ     TEXT;
    v_kind    TEXT;
BEGIN
    IF jsonb_typeof(v_idx) IS DISTINCT FROM 'object' OR jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'reason', 'The file is not a readable table.');
    END IF;

    FOR v_row, v_n IN SELECT e, (o)::int FROM jsonb_array_elements(p->'rows') WITH ORDINALITY AS x(e, o) LOOP
        -- komplett leere Zeile (Dateiende, Leerzeile) ueberspringen
        CONTINUE WHEN jsonb_typeof(v_row) <> 'array'
            OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_row) c WHERE btrim(c) <> '');
        v_bd  := NULLIF(btrim(v_row->>((v_idx->>'booking date')::int)), '');
        v_raw := NULLIF(btrim(v_row->>((v_idx->>'amount (eur)')::int)), '');
        -- Zahl strikt (Punkt als Dezimaltrenner, keine Tausender, kein NaN/Infinity/Exponent): bricht laut ab
        IF v_raw IS NULL OR v_raw !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', v_n + v_hrow,
                'reason', 'Row ' || (v_n + v_hrow) || ': "Amount (EUR)" is not a number (' || COALESCE(v_raw, 'empty') || ').');
        END IF;
        -- nur ISO-Datum ("03/04/2026" waere je nach DateStyle 3. April oder 4. Maerz); ohne Buchungstag kein Platz im
        -- Zeitraum -> laut statt still verworfen
        IF v_bd IS NULL OR v_bd !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR NOT pg_input_is_valid(v_bd, 'date') THEN
            RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', v_n + v_hrow,
                'reason', 'Row ' || (v_n + v_hrow) || ' has no readable booking date (YYYY-MM-DD).');
        END IF;
        v_amt     := round(v_raw::numeric, 2);
        v_iban    := NULLIF(upper(regexp_replace(COALESCE(v_row->>((v_idx->>'partner iban')::int), ''), '\s', '', 'g')), '');
        v_partner := NULLIF(btrim(v_row->>((v_idx->>'partner name')::int)), '');
        v_ref     := NULLIF(btrim(v_row->>((v_idx->>'payment reference')::int)), '');
        v_typ     := NULLIF(btrim(v_row->>((v_idx->>'type')::int)), '');
        v_kind    := CASE WHEN lower(v_typ) IN ('presentment', 'debit transfer', 'credit transfer', 'direct debit', 'moneybeam')
                          THEN 'cash' ELSE 'unknown' END;
        v_arr := v_arr || jsonb_build_object(
            'row_no', v_n + v_hrow, 'date', v_bd::date, 'kind', v_kind, 'type', v_typ, 'cash_amount', v_amt,
            'counterparty', v_partner, 'counterparty_iban', v_iban, 'purpose', v_ref, 'name', v_partner,
            'account_type', NULLIF(btrim(v_row->>((v_idx->>'account name')::int)), ''),
            'reason', CASE WHEN v_kind = 'unknown' THEN 'unsupported_type' END,
            -- Schluessel als JSON-Array: Trennzeichen im Freitext koennen zwei Zeilen nie gleich machen
            'k', jsonb_build_array(v_bd, v_amt::text, v_iban, v_partner, v_ref)::text);
    END LOOP;

    -- ext_ref: laufende Nummer je gleichem Schluessel in Dateifolge (zwei gleiche Parkscheine am selben Tag = zwei Zeilen)
    SELECT COALESCE(jsonb_agg((e - 'k') || jsonb_build_object('ext_ref', md5((e->>'k') || '|' || rn)) ORDER BY (e->>'row_no')::int), '[]'::jsonb)
    INTO v_out
    FROM (SELECT e, row_number() OVER (PARTITION BY e->>'k' ORDER BY (e->>'row_no')::int) AS rn
          FROM unnest(v_arr) AS u(e)) s;

    RETURN jsonb_build_object('ok', true, 'rows', v_out,
        'unknown_rows', (SELECT COALESCE(jsonb_agg(jsonb_build_object('row_no', r->'row_no', 'date', r->'date', 'type', r->'type',
                             'cash_amount', r->'cash_amount', 'name', COALESCE(r->>'name', r->>'purpose'), 'reason', r->'reason')
                             ORDER BY (r->>'row_no')::int), '[]'::jsonb)
                         FROM jsonb_array_elements(v_out) r WHERE r->>'kind' = 'unknown'),
        'account_types', (SELECT COALESCE(jsonb_agg(DISTINCT r->>'account_type'), '[]'::jsonb)
                          FROM jsonb_array_elements(v_out) r WHERE r->>'account_type' IS NOT NULL),
        'currencies', CASE WHEN jsonb_array_length(v_out) > 0 THEN '["EUR"]'::jsonb ELSE '[]'::jsonb END);
END;
$$;
