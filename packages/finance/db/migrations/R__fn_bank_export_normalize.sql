-- ============================================================
-- fn_bank_export_normalize (READ, IMMUTABLE) -- Bank-Export-Datei -> kanonische Importzeilen (Bank-Import-Modul)
--   Dispatcher: Eingabe = Raster des Lesers im Workflow {rows:[[text]]} (CSV-Tokenizer bzw. xlsx ueber Extract From
--   File; die Bedeutung kennt der Leser nicht, die Kopfzeile steht im Raster). Sucht in den ersten 20 Zeilen die erste,
--   die alle required-Spalten eines Profils aus fn_bank_export_profiles traegt (Kleinschreibung, getrimmt, header_aliases
--   des Profils -> kanonischer Name), und ruft die
--   Profil-fn per festem CASE (kein dynamisches EXECUTE) mit {columns (Spaltenname der Kopfzeile, bereinigt wie bei der
--   Erkennung -> 0-basierter Index, erste Fundstelle; die EINE Bereinigung, Leser bauen keine eigene), rows (danach),
--   preamble (davor), header_row_no}.
--   KANONISCHE IMPORTZEILE (Vertrag fuer fn_statement_prepare; der gedruckte Auszug liefert dieselben Felder als lines):
--   {row_no, date, kind, cash_amount (signiert, Cent), counterparty, counterparty_iban, purpose, name, ext_ref, reason,
--   + Wertpapier-Felder isin/symbol/shares/price/gross/fee/tax (TR)}; kind cash|fee|interest|buy|sell|dividend|tax|
--   corporate|unknown, unknown nie still verworfen (unknown_rows).
--   plpgsql (late-bound): die Profil-fns und fn_bank_export_profiles liegen alphabetisch spaeter.
--   RUECKGABE: Profil-Rueckgabe || {profile, printed_balance (Registry; dann traegt die Profil-Rueckgabe statement)}
--   | {ok:false, code:'export_profile_unknown'|'export_invalid', reason, row_no?}.
--   Fehlertexte nennen nie Zellinhalte des Vorspanns (dort kann der Inhabername stehen).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_normalize(p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_prof JSONB;
    v_hrow INT;
    v_in   JSONB;
    v_res  JSONB;
BEGIN
    IF jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'reason', 'The file is not a readable table.');
    END IF;
    SELECT pr, x.o INTO v_prof, v_hrow
    FROM jsonb_array_elements(p->'rows') WITH ORDINALITY AS x(r, o)
    CROSS JOIN LATERAL jsonb_array_elements(finance.fn_bank_export_profiles()) WITH ORDINALITY AS y(pr, po)
    WHERE x.o <= 20 AND jsonb_typeof(x.r) = 'array'
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(pr->'required') c
                      WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(x.r) h
                                        CROSS JOIN LATERAL (SELECT lower(btrim(h, E' \t\r\n"\uFEFF')) AS k) n
                                        WHERE COALESCE(pr->'header_aliases'->>n.k, n.k) = c))
    ORDER BY x.o, y.po LIMIT 1;
    IF v_prof IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_profile_unknown',
            'reason', 'This export is not from a supported bank (known: '
                   || (SELECT string_agg(pr->>'bank', ', ') FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr)
                   || ') or its columns changed.');
    END IF;
    v_in := jsonb_build_object('header_row_no', v_hrow,
        'columns', (SELECT jsonb_object_agg(h, o - 1)
                    FROM (SELECT DISTINCT ON (n.h) n.h, x.o
                          FROM jsonb_array_elements_text(p->'rows'->(v_hrow - 1)) WITH ORDINALITY AS x(h, o)
                          CROSS JOIN LATERAL (SELECT lower(btrim(x.h, E' \t\r\n"\uFEFF')) AS k) c
                          CROSS JOIN LATERAL (SELECT COALESCE(v_prof->'header_aliases'->>c.k, c.k) AS h) n
                          ORDER BY n.h, x.o) s),
        'rows', COALESCE((SELECT jsonb_agg(r ORDER BY o) FROM jsonb_array_elements(p->'rows') WITH ORDINALITY AS x(r, o)
                          WHERE o > v_hrow), '[]'::jsonb),
        'preamble', COALESCE((SELECT jsonb_agg(r ORDER BY o) FROM jsonb_array_elements(p->'rows') WITH ORDINALITY AS x(r, o)
                              WHERE o < v_hrow), '[]'::jsonb));
    v_res := CASE v_prof->>'key'
        WHEN 'trade_republic_v1' THEN finance.fn_bank_export_normalize_trade_republic(v_in)
        WHEN 'bondora_go_grow_v1' THEN finance.fn_bank_export_normalize_bondora(v_in)
        WHEN 'n26_v1' THEN finance.fn_bank_export_normalize_n26(v_in)
    END;
    IF v_res IS NULL THEN
        RAISE EXCEPTION 'fn_bank_export_normalize: profile % has no reader', v_prof->>'key';
    END IF;
    IF (v_res->>'ok')::boolean AND COALESCE((v_prof->>'printed_balance')::boolean, false) AND NOT (v_res ? 'statement') THEN
        RAISE EXCEPTION 'fn_bank_export_normalize: profile % prints its balance but its reader returned no statement', v_prof->>'key';
    END IF;
    RETURN CASE WHEN (v_res->>'ok')::boolean
                THEN v_res || jsonb_build_object('profile', v_prof->>'key',
                                                 'printed_balance', COALESCE((v_prof->>'printed_balance')::boolean, false))
                ELSE v_res END;
END;
$$;
