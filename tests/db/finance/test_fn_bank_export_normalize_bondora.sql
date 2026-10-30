-- ============================================================
-- test_fn_bank_export_normalize_bondora -- Golden-File Profil bondora_go_grow_v1 (Bank-Import-Modul Paket 2)
--   finance.fn_bank_export_normalize (Dispatcher) -> fn_bank_export_normalize_bondora. Raster wie der xlsx-Leser es
--   liefert (Blatt "Data": Kopfblock Summary/Opening/Payments in/Payments out/Closing, Zeitraum M/D/YYYY-M/D/YYYY,
--   "All Goals", Kopfzeile Date|Payment type|In|Out|Balance). Werte frei erfunden. Deckt: Profil per Kopfzeile hinter
--   dem Vorspann, gedruckter Auszug (statement), Vorzeichen aus In/Out, Float-Artefakte, Zins, Kleinbetrag (legacy_return),
--   Einzahlung, Auszahlung mit Gebuehr, Info-Zeile saldo-neutral (nicht in rows), unbekannter Typ, ISO-Datum,
--   Bruch im laufenden Saldo / Kopf-Summe / fehlender Kopfblock -> export_invalid ohne Vorspann-Inhalt im Text;
--   deutsche Export-Variante (Kopfzeilen-Aliase, deutscher Kopfblock, TT.MM.JJJJ, deutsche Zahlungsarten).
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_head JSONB := jsonb_build_array(
        '["Test Person","","","Summary",""]'::jsonb,
        '["9/1/2026-9/30/2026","","","Opening","100"]'::jsonb,
        '["","","","Payments in","509.88"]'::jsonb,
        '["","","","Payments out","201"]'::jsonb,
        '["","","","Closing","408.88"]'::jsonb,
        '[]'::jsonb,
        '["All Goals"]'::jsonb,
        '["Date","Payment type","In","Out","Balance"]'::jsonb);
    v_data JSONB := jsonb_build_array(
        '["9/1/2026","Go & Grow returns","0.02","","100.02"]'::jsonb,
        '["9/2/2026","SEPA payment","0.15","","100.17"]'::jsonb,
        '["9/2/2026","Unallocated balance - Liquidity","0.05","","100.17"]'::jsonb,
        '["9/3/2026","SEPA payment","500","","600.17"]'::jsonb,
        '["2026-09-04T00:00:00.000Z","Go & Grow returns","8.7100000000000009","","608.88"]'::jsonb,
        '["9/10/2026","Withdrawal to bank account","","201","407.88"]'::jsonb,
        '["9/11/2026","Something new","1","","408.88"]'::jsonb);
    v_res JSONB;
    v_r   JSONB;
    v_s   TEXT;
BEGIN
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', v_head || v_data));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'profile' IS DISTINCT FROM 'bondora_go_grow_v1' THEN
        RAISE EXCEPTION 'FAIL [B1 Profil erkannt]: %', v_res;
    END IF;
    IF v_res->'statement' IS DISTINCT FROM jsonb_build_object('period_start', '2026-09-01', 'period_end', '2026-09-30',
           'opening_balance', 100.00, 'closing_balance', 408.88) THEN
        RAISE EXCEPTION 'FAIL [B2 gedruckter Kopf]: %', v_res->'statement';
    END IF;
    IF jsonb_array_length(v_res->'rows') <> 6 OR (v_res->>'info_count')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [B3 Info-Zeile nicht in rows]: % / %', jsonb_array_length(v_res->'rows'), v_res->>'info_count';
    END IF;
    RAISE NOTICE 'PASS [B1-B3 Profil, Kopf, Info-Zeile]';

    SELECT string_agg(r->>'kind' || ':' || COALESCE(r->>'sub_kind', '-') || ':' || (r->>'cash_amount'), ',' ORDER BY (r->>'row_no')::int)
    INTO v_s FROM jsonb_array_elements(v_res->'rows') r;
    IF v_s IS DISTINCT FROM 'interest:-:0.02,cash:legacy_return:0.15,cash:deposit:500.00,interest:-:8.71,cash:withdrawal:-201.00,unknown:-:1.00' THEN
        RAISE EXCEPTION 'FAIL [B4 Zeilenarten + Vorzeichen aus In/Out]: %', v_s;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE r->>'sub_kind' = 'withdrawal';
    IF (v_r->>'transfer_fee')::numeric <> 1.00 OR (v_r->>'row_no')::int <> 14 OR (v_r->>'date')::date <> DATE '2026-09-10' THEN
        RAISE EXCEPTION 'FAIL [B5 Auszahlung: Gebuehr, Datei-Zeile, US-Datum]: %', v_r;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 13;
    IF (v_r->>'date')::date <> DATE '2026-09-04' THEN RAISE EXCEPTION 'FAIL [B6 ISO-Datum aus Excel]: %', v_r; END IF;
    IF jsonb_array_length(v_res->'unknown_rows') <> 1 OR v_res->'unknown_rows'->0->>'type' <> 'Something new' THEN
        RAISE EXCEPTION 'FAIL [B7 unknown_rows]: %', v_res->'unknown_rows';
    END IF;
    RAISE NOTICE 'PASS [B4-B7 Zuordnung]';

    -- laufender Saldo gebrochen (Zeile 12: 500 statt 600.17) -> laut, mit Datei-Zeile
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', v_head || jsonb_set(v_data, '{3,4}', '"500"')));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 12 THEN
        RAISE EXCEPTION 'FAIL [B8 laufender Saldo]: %', v_res;
    END IF;
    -- Info-Zeile, die den Saldo doch aendert -> Bruch (nie still verworfen)
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', v_head || jsonb_set(v_data, '{2,4}', '"100.22"')));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 11 THEN
        RAISE EXCEPTION 'FAIL [B9 Info-Zeile aendert Saldo]: %', v_res;
    END IF;
    -- Kopf-Summe passt nicht zu den Zeilen (Closing 400) -> export_invalid, ohne Vorspann-Inhalt (Inhabername) im Text
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_set(v_head, '{4,4}', '"400"') || v_data));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR position('Test Person' IN v_res->>'reason') > 0 THEN
        RAISE EXCEPTION 'FAIL [B10 Kopf-Summe]: %', v_res;
    END IF;
    -- ohne Kopfblock (nur Kopfzeile + Daten) -> export_invalid
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(v_head->7) || v_data));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' THEN RAISE EXCEPTION 'FAIL [B11 Kopfblock fehlt]: %', v_res; END IF;
    -- Zeile ausserhalb des gedruckten Zeitraums -> export_invalid (nie ein Oktober-Transfer im September-Auszug)
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', v_head || jsonb_set(v_data, '{6,0}', '"10/2/2026"')));
    IF v_res->>'code' IS DISTINCT FROM 'export_invalid' OR (v_res->>'row_no')::int <> 15 THEN
        RAISE EXCEPTION 'FAIL [B11b Zeile ausserhalb des Zeitraums]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [B8-B11 Ablehnungen]';
    -- Auszahlung nicht groesser als die Gebuehr -> keine Gebuehr (sonst bliebe ein Transfer ueber 0)
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(
        '["","","","Summary",""]'::jsonb, '["9/1/2026-9/30/2026","","","Opening","10"]'::jsonb,
        '["","","","Payments in","0"]'::jsonb, '["","","","Payments out","1"]'::jsonb, '["","","","Closing","9"]'::jsonb,
        v_head->7, '["9/5/2026","Withdrawal to bank account","","1","9"]'::jsonb)));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->'rows'->0->'transfer_fee' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FAIL [B11c Mini-Auszahlung ohne Gebuehr]: %', v_res;
    END IF;

    -- Registry: Bondora mit gedrucktem Endstand + Gebuehr + Kleinbetrag-Grenze; TR ohne gedruckten Endstand
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr
                   WHERE pr->>'key' = 'bondora_go_grow_v1' AND (pr->>'printed_balance')::boolean
                     AND (pr->>'withdrawal_fee')::numeric = 1.00 AND (pr->>'small_inflow_max')::numeric = 1.00)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr
                  WHERE pr->>'key' = 'trade_republic_v1' AND (pr->>'printed_balance')::boolean) THEN
        RAISE EXCEPTION 'FAIL [B12 Registry]: %', finance.fn_bank_export_profiles();
    END IF;
    RAISE NOTICE 'PASS [B12 Registry]';

    -- Deutsche Export-Variante (Bondora-Sprache Deutsch, Livebefund 2026-10-30, gleicher Aufbau): Kopfzeile Datum|
    -- Zahlungsart|Eingaenge|Ausgaenge|Guthaben, Kopfblock Zu Beginn/Einzahlungen/Auszahlungen/Ergebnis, Daten TT.MM.JJJJ
    v_res := finance.fn_bank_export_normalize(jsonb_build_object('rows', jsonb_build_array(
        '["Test Person","","","Zusammenfassung",""]'::jsonb,
        '["01.09.2026-30.09.2026","","","Zu Beginn",100]'::jsonb,
        '["","","","Einzahlungen",509.88]'::jsonb,
        '["","","","Auszahlungen",201]'::jsonb,
        '["","","","Ergebnis",408.88]'::jsonb,
        '["","","","",""]'::jsonb,
        '["Alle Ziele","","","",""]'::jsonb,
        '["Datum","Zahlungsart","Eingänge","Ausgänge","Guthaben"]'::jsonb,
        '["01.09.2026","Go & Grow Zinsen","0.02","","100.02"]'::jsonb,
        '["02.09.2026","SEPA-Banküberweisung","0.15","","100.17"]'::jsonb,
        '["03.09.2026","SEPA-Banküberweisung","500","","600.17"]'::jsonb,
        '["04.09.2026","Go & Grow Zinsen","8.7100000000000009","","608.88"]'::jsonb,
        '["10.09.2026","Abheben auf Bankkonto","","201","407.88"]'::jsonb,
        '["11.09.2026","Automatische Überweisung","1","","408.88"]'::jsonb)));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'profile' IS DISTINCT FROM 'bondora_go_grow_v1' THEN
        RAISE EXCEPTION 'FAIL [B13 deutscher Export erkannt]: %', v_res;
    END IF;
    IF v_res->'statement' IS DISTINCT FROM jsonb_build_object('period_start', '2026-09-01', 'period_end', '2026-09-30',
           'opening_balance', 100.00, 'closing_balance', 408.88) THEN
        RAISE EXCEPTION 'FAIL [B14 deutscher Kopfblock + Zeitraum TT.MM.JJJJ]: %', v_res->'statement';
    END IF;
    SELECT string_agg(r->>'kind' || ':' || COALESCE(r->>'sub_kind', '-') || ':' || (r->>'cash_amount'), ',' ORDER BY (r->>'row_no')::int)
    INTO v_s FROM jsonb_array_elements(v_res->'rows') r;
    IF v_s IS DISTINCT FROM 'interest:-:0.02,cash:legacy_return:0.15,cash:deposit:500.00,interest:-:8.71,cash:withdrawal:-201.00,unknown:-:1.00' THEN
        RAISE EXCEPTION 'FAIL [B15 deutsche Zahlungsarten]: %', v_s;
    END IF;
    SELECT r INTO v_r FROM jsonb_array_elements(v_res->'rows') r WHERE r->>'sub_kind' = 'withdrawal';
    IF (v_r->>'transfer_fee')::numeric <> 1.00 OR (v_r->>'row_no')::int <> 13 OR (v_r->>'date')::date <> DATE '2026-09-10' THEN
        RAISE EXCEPTION 'FAIL [B16 Auszahlung deutsch: Gebuehr, Datei-Zeile, Datum TT.MM.]: %', v_r;
    END IF;
    IF (SELECT (r->>'date')::date FROM jsonb_array_elements(v_res->'rows') r WHERE (r->>'row_no')::int = 10) <> DATE '2026-09-02' THEN
        RAISE EXCEPTION 'FAIL [B17 02.09. ist der 2. September, nicht der 9. Februar]: %', v_res->'rows';
    END IF;
    RAISE NOTICE 'PASS [B13-B17 deutscher Export]';
END $$;
ROLLBACK;
