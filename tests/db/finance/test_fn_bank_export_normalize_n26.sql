-- ============================================================
-- test_fn_bank_export_normalize_n26 -- Golden-File Profil n26_v1 (Bank-Import-Modul)
--   finance.fn_bank_export_normalize (Dispatcher) -> fn_bank_export_normalize_n26 / fn_bank_export_profiles /
--   fn_bank_export_account_profile. Fixture = N26-Spaltenform (CSV-Export seit 2025), Werte frei erfunden.
--   Deckt: Profil-Erkennung (keine Kollision mit TR/Bondora, altes N26-Format unbekannt, BOM/Quotes), Buchungstag vor
--   Valuta, ganzzahlige Betraege, IBAN normalisiert, die fuenf bekannten Typen -> cash, unbekannter Typ -> unknown_rows,
--   ext_ref (32-Hex, Zwillinge verschieden, stabil gegen Space-Name/Betragsschreibweise), Leerzeile, unlesbare
--   Fremdwaehrungsspalte egal, unlesbarer Betrag (auch NaN/Exponent)/mehrdeutiges oder fehlendes Datum -> export_invalid,
--   Trennzeichen im Freitext, Name-Rueckfall auf die Referenz, Spaces -> account_types, Konto -> Profil (auch "N 26", "Trade-Republic").
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_hdr JSONB := '["Booking Date","Value Date","Partner Name","Partner Iban","Type","Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"]';
    v_rows JSONB := jsonb_build_array(
        -- 2: Kartenzahlung, Buchungstag einen Tag nach Valuta, ganzzahliger Betrag
        '["2026-09-03","2026-09-02","Baeckerei Test","","Presentment","","Hauptkonto","-30","30","EUR","1"]'::jsonb,
        -- 3: Ueberweisung an eine IBAN mit Leerzeichen
        '["2026-09-04","2026-09-04","Erika Muster","de89 3704 0044 0532 0130 00","Debit Transfer","Miete September","Hauptkonto","-500.00","","",""]'::jsonb,
        -- 4: Gutschrift
        '["2026-09-05","2026-09-05","Testfirma GmbH","DE02120300000000202051","Credit Transfer","Gehalt September","Hauptkonto","2500.00","","",""]'::jsonb,
        -- 5: Lastschrift
        '["2026-09-05","2026-09-05","Teststrom AG","DE02500105170137075030","Direct Debit","Abschlag 09","Hauptkonto","-45.50","","",""]'::jsonb,
        -- 6: MoneyBeam ohne Referenz
        '["2026-09-06","2026-09-06","Lisa Muster","DE02100100100006820101","MoneyBeam","","Hauptkonto","50","","",""]'::jsonb,
        -- 7: unbekannter Typ -> unknown, Geld zaehlt trotzdem
        '["2026-09-06","2026-09-06","Testdienst","","Something New","","Hauptkonto","-3.33","","",""]'::jsonb,
        -- 8 + 9: identische Zwillinge (zwei Parkscheine am selben Tag)
        '["2026-09-07","2026-09-07","Parkhaus Test","","Presentment","","Hauptkonto","-3","3","EUR","1"]'::jsonb,
        '["2026-09-07","2026-09-07","Parkhaus Test","","Presentment","","Hauptkonto","-3","3","EUR","1"]'::jsonb,
        -- 10: Leerzeile
        '["","","","","","","","","","",""]'::jsonb,
        -- 11: Fremdwaehrung mit unlesbarem Kurs -> egal, es zaehlt der EUR-Betrag
        '["2026-09-09","2026-09-08","Shop London","","Presentment","","Hauptkonto","-11.70","10.00","GBP","n/a"]'::jsonb);
    v_res  JSONB;
    v_r    JSONB;
    v_ref  TEXT;
    v_acct INT;
BEGIN
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'profile' IS DISTINCT FROM 'n26_v1'
       OR (v_res->>'printed_balance')::boolean THEN
        RAISE EXCEPTION 'FAIL [M1 Profil erkannt]: %', v_res;
    END IF;
    IF jsonb_array_length(v_res->'rows') <> 9 THEN
        RAISE EXCEPTION 'FAIL [M2 9 Zeilen, Leerzeile uebersprungen]: %', jsonb_array_length(v_res->'rows');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr
                   WHERE pr->>'key' = 'n26_v1' AND pr->>'bank' = 'N26' AND NOT (pr->>'printed_balance')::boolean
                     AND pr->'required' = '["booking date","value date","partner name","type","amount (eur)"]'::jsonb) THEN
        RAISE EXCEPTION 'FAIL [M0 Registry]: %', finance.fn_bank_export_profiles();
    END IF;
    RAISE NOTICE 'PASS [M0-M2 Profil + Zeilen]';

    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 2;
    IF v_r->>'kind' <> 'cash' OR (v_r->>'date')::date <> DATE '2026-09-03' OR (v_r->>'cash_amount')::numeric <> -30.00
       OR v_r->>'counterparty' <> 'Baeckerei Test' OR v_r->>'counterparty_iban' IS NOT NULL
       OR v_r->>'purpose' IS NOT NULL OR v_r->>'account_type' <> 'Hauptkonto' THEN
        RAISE EXCEPTION 'FAIL [M3 Karte: Buchungstag, ganzzahlig]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 3;
    IF v_r->>'kind' <> 'cash' OR (v_r->>'cash_amount')::numeric <> -500 OR v_r->>'counterparty_iban' <> 'DE89370400440532013000'
       OR v_r->>'purpose' <> 'Miete September' OR v_r->>'type' <> 'Debit Transfer' THEN
        RAISE EXCEPTION 'FAIL [M4 Ueberweisung, IBAN normalisiert]: %', v_r;
    END IF;
    IF (SELECT string_agg((r->>'row_no') || ':' || (r->>'kind') || ':' || (r->>'cash_amount'), ',' ORDER BY (r->>'row_no')::int)
        FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int IN (4, 5, 6, 11))
       IS DISTINCT FROM '4:cash:2500.00,5:cash:-45.50,6:cash:50.00,11:cash:-11.70' THEN
        RAISE EXCEPTION 'FAIL [M5 Gutschrift/Lastschrift/MoneyBeam/Fremdwaehrung]: %', v_res->'rows';
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 7;
    IF v_r->>'kind' <> 'unknown' OR v_r->>'reason' <> 'unsupported_type' OR (v_r->>'cash_amount')::numeric <> -3.33 THEN
        RAISE EXCEPTION 'FAIL [M6 unbekannter Typ]: %', v_r;
    END IF;
    IF jsonb_array_length(v_res->'unknown_rows') <> 1
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'unknown_rows') u WHERE (u->>'row_no')::int = 7
                      AND u->>'type' = 'Something New' AND u->>'name' = 'Testdienst' AND (u->>'cash_amount')::numeric = -3.33) THEN
        RAISE EXCEPTION 'FAIL [M7 unknown_rows]: %', v_res->'unknown_rows';
    END IF;
    IF v_res->'account_types' <> '["Hauptkonto"]'::jsonb OR v_res->'currencies' <> '["EUR"]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [M8 Unterkonten/Waehrung]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [M3-M8 Zuordnung]';

    -- ext_ref: 32-Hex (CHECK statement_seen_refs.ref_hash), eindeutig je Zeile, Zwillinge verschieden
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'rows') r WHERE r->>'ext_ref' IS NULL OR r->>'ext_ref' !~ '^[0-9a-f]{32}$')
       OR (SELECT count(DISTINCT r->>'ext_ref') FROM jsonb_array_elements(v_res->'rows') r) <> 9 THEN
        RAISE EXCEPTION 'FAIL [M9 ext_ref 32-Hex + eindeutig]: %', v_res->'rows';
    END IF;
    -- stabil: dieselbe Kartenzahlung mit umbenanntem Space und "-30.00" statt "-30" -> gleiche ext_ref
    SELECT r->>'ext_ref' INTO v_ref FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 2;
    v_r := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
               '["2026-09-03","2026-09-03","Baeckerei Test","","Presentment","","Main Account","-30.00","","",""]'::jsonb)));
    IF v_r->'rows'->0->>'ext_ref' IS DISTINCT FROM v_ref THEN
        RAISE EXCEPTION 'FAIL [M10 ext_ref stabil]: % vs %', v_r->'rows'->0->>'ext_ref', v_ref;
    END IF;
    -- der erste Zwilling allein hat dieselbe ext_ref wie im vollen Export (laufende Nummer je gleicher Zeile)
    SELECT r->>'ext_ref' INTO v_ref FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 8;
    v_r := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr, v_rows->6)));
    IF v_r->'rows'->0->>'ext_ref' IS DISTINCT FROM v_ref THEN
        RAISE EXCEPTION 'FAIL [M11 Zwilling 1 stabil]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [M9-M11 ext_ref]';

    -- ---------- Erkennung ----------
    -- BOM + Quotes im Kopf egal
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows',
        '[["﻿\"Booking Date\"","Value Date","Partner Name","Type","Amount (EUR)"],["2026-09-02","2026-09-02","Test","Presentment","-1.00"]]'::jsonb));
    IF v_res->>'profile' IS DISTINCT FROM 'n26_v1' OR (v_res->'rows'->0->>'cash_amount')::numeric <> -1 THEN
        RAISE EXCEPTION 'FAIL [M12 BOM/Quotes, Mindest-Kopf]: %', v_res;
    END IF;
    -- TR-Kopf bleibt TR
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows',
        '[["datetime","category","type","amount","currency"],["2026-09-02T08:00:00Z","CASH","TRANSFER_IN","5.00","EUR"]]'::jsonb));
    IF v_res->>'profile' IS DISTINCT FROM 'trade_republic_v1' THEN
        RAISE EXCEPTION 'FAIL [M13 TR-Kopf]: %', v_res;
    END IF;
    -- alte N26-Formate (deutsch / englisch bis ~2024) -> nicht unterstuetzt
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows',
        '[["Datum","Empfänger","Kontonummer","Transaktionstyp","Verwendungszweck","Betrag (EUR)"],["2026-09-02","Test","","MasterCard Zahlung","","-1.00"]]'::jsonb));
    IF v_res->>'code' IS DISTINCT FROM 'export_profile_unknown' THEN
        RAISE EXCEPTION 'FAIL [M14 altes Format deutsch]: %', v_res;
    END IF;
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows',
        '[["Date","Payee","Account number","Transaction type","Payment reference","Amount (EUR)"],["2026-09-02","Test","","Presentment","","-1.00"]]'::jsonb));
    IF v_res->>'code' IS DISTINCT FROM 'export_profile_unknown' THEN
        RAISE EXCEPTION 'FAIL [M15 altes Format englisch]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [M12-M15 Erkennung]';

    -- ---------- Ablehnungen ----------
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr, v_rows->0,
                 jsonb_set(v_rows->1, '{7}', '"1,00"'))));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 3 THEN
        RAISE EXCEPTION 'FAIL [M16 unlesbarer Betrag]: %', v_res;
    END IF;
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
                 jsonb_set(v_rows->0, '{0}', '"03/09/2026"'))));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 2 THEN
        RAISE EXCEPTION 'FAIL [M17 mehrdeutiges Datum]: %', v_res;
    END IF;
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
                 jsonb_set(v_rows->0, '{7}', '""'))));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 2 THEN
        RAISE EXCEPTION 'FAIL [M18 fehlender Betrag]: %', v_res;
    END IF;
    -- ohne Buchungstag (Vormerkung) kein Platz im Zeitraum -> laut, nie still verworfen
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr, v_rows->0,
                 jsonb_set(v_rows->1, '{0}', '""'))));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 3 THEN
        RAISE EXCEPTION 'FAIL [M18b ohne Buchungstag]: %', v_res;
    END IF;
    -- NaN/Infinity/Exponent sind fuer pg numeric gueltig, aber kein Betrag
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
                 jsonb_set(v_rows->0, '{7}', '"NaN"'))));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' THEN
        RAISE EXCEPTION 'FAIL [M18c NaN]: %', v_res;
    END IF;
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
                 jsonb_set(v_rows->0, '{7}', '"-1e3"'))));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' THEN
        RAISE EXCEPTION 'FAIL [M18d Exponent]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [M16-M18 Ablehnungen]';

    -- Trennzeichen im Freitext machen zwei verschiedene Zeilen nie gleich (Schluessel = JSON-Array)
    IF finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
           '["2026-09-10","2026-09-10","A|B","","Presentment","","Hauptkonto","-1.00","","",""]'::jsonb)))->'rows'->0->>'ext_ref'
       = finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
           '["2026-09-10","2026-09-10","A","","Presentment","B|","Hauptkonto","-1.00","","",""]'::jsonb)))->'rows'->0->>'ext_ref' THEN
        RAISE EXCEPTION 'FAIL [M18e Schluessel-Kollision]';
    END IF;
    -- unbekannter Typ ohne Partner: Name faellt auf die Referenz zurueck
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr,
                 '["2026-09-10","2026-09-10","","","Fee","Kontofuehrung","Hauptkonto","-2.90","","",""]'::jsonb)));
    IF v_res->'unknown_rows'->0->>'name' IS DISTINCT FROM 'Kontofuehrung' THEN
        RAISE EXCEPTION 'FAIL [M18f Name-Rueckfall]: %', v_res->'unknown_rows';
    END IF;
    RAISE NOTICE 'PASS [M18e-M18f Schluessel + Name]';

    -- Spaces gemischt -> zwei Unterkonten (der Prepare-Waechter multiple_sub_accounts greift)
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_hdr, v_rows->0,
                 jsonb_set(v_rows->1, '{6}', '"Reise"'))));
    IF jsonb_array_length(v_res->'account_types') <> 2 THEN
        RAISE EXCEPTION 'FAIL [M19 Spaces]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [M19 Spaces]';

    -- ---------- Konto -> Profil ----------
    v_acct := (finance.fn_create_account('{"name":"__t_n26_a__","account_type":"cash","currency":"EUR","bank":"N26"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'n26_v1' THEN RAISE EXCEPTION 'FAIL [M20 Bank N26]'; END IF;
    v_acct := (finance.fn_create_account('{"name":"__t_n26_b__","account_type":"cash","currency":"EUR","bank":"N 26 Bank"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'n26_v1' THEN RAISE EXCEPTION 'FAIL [M21 Bank N 26]'; END IF;
    v_acct := (finance.fn_create_account('{"name":"__t_n26_c__","account_type":"cash","currency":"EUR","bank":"Konto 1N260"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [M22 N26 nur als eigenes Wort]'; END IF;
    v_acct := (finance.fn_create_account('{"name":"__t_n26_d__","account_type":"cash","currency":"EUR","bank":"Trade-Republic"}'::jsonb)->>'account_id')::int;
    IF finance.fn_bank_export_account_profile(v_acct) IS DISTINCT FROM 'trade_republic_v1' THEN RAISE EXCEPTION 'FAIL [M23 Trade-Republic]'; END IF;
    RAISE NOTICE 'PASS [M20-M23 Konto-Profil]';
END $$;
ROLLBACK;
