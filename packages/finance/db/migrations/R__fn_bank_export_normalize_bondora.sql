-- ============================================================
-- fn_bank_export_normalize_bondora (READ, IMMUTABLE) -- Profil bondora_go_grow_v1 des Bank-Import-Moduls
--   Fester Leser in Code, kein LLM. Aufruf NUR ueber den Dispatcher fn_bank_export_normalize: Eingabe {columns
--   (Spaltenname -> Index), rows (nach der Kopfzeile Date|Payment type|In|Out|Balance), preamble (Kopfblock davor), header_row_no}.
--   Kopfblock (Bondora-Kontoauszug, Blatt "Data"): Labels Opening / Payments in / Payments out / Closing mit dem Wert
--   in der naechsten nicht leeren Zelle rechts daneben, Zeitraum M/D/YYYY-M/D/YYYY (US-Format) -> statement
--   (gedruckter Auszug, balance_source printed). Weitere Zellen (Inhabername) werden nie gelesen oder zurueckgegeben.
--   Deutsche Export-Variante (gleicher Aufbau, Livebefund 2026-10-30): Kopfzeile ueber header_aliases des Profils,
--   Labels Zu Beginn / Einzahlungen / Auszahlungen / Ergebnis, Zeitraum und Daten TT.MM.JJJJ, Typen "go & grow zinsen",
--   "sepa-banküberweisung", "abheben auf bankkonto" (Belege: Portfolio-Performance-Forum, deutsche Bondora-Auszuege).
--   Zeilen: Datum M/D/YYYY, TT.MM.JJJJ oder ISO (Excel-Datumszelle), Zahlen ungerundet (Float-Artefakte) -> auf Cent gerundet;
--   cash_amount = In - Out (das Vorzeichen kommt nie aus dem Typ-Text).
--   Typen (Kleinschreibung): "go & grow returns" -> kind interest; "sepa payment" unter small_inflow_max (Profil) ->
--   cash/legacy_return (Rueckfluesse alter Bondora-Kredite ausserhalb Go&Grow, Owner-Entscheid 2026-10-29), sonst
--   cash/deposit; "withdrawal to bank account" -> cash/withdrawal mit transfer_fee = withdrawal_fee (Profil, hoechstens
--   der Betrag); "unallocated balance..." -> Info-Zeile (aendert den Saldo nicht, fehlt in "Payments in"): nicht in rows,
--   nur info_count; alles andere -> unknown (nie still verworfen).
--   Pruefungen (sonst export_invalid mit row_no): laufender Saldo je Zeile (vorige Balance bzw. Opening + cash = Balance;
--   Info-Zeile: Balance unveraendert), Opening + Summe = Closing, Summe In/Out = Payments in/out. Absteigend sortierte
--   Dateien werden in Datumsfolge geprueft.
--   RUECKGABE: {ok:true, rows:[{row_no, date, kind, sub_kind, cash_amount, transfer_fee, name, purpose, type, reason}],
--   unknown_rows:[{row_no, date, type, cash_amount, name, reason}], info_count, statement:{period_start, period_end,
--   opening_balance, closing_balance}, legacy_return_label, account_types:[], currencies:[]}
--   | {ok:false, code:'export_invalid', reason, row_no?} (auch: Zeile ausserhalb des gedruckten Zeitraums, Zeitraum verkehrt).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_normalize_bondora(p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_prof    JSONB;
    v_hrow    INT := COALESCE((p->>'header_row_no')::int, 1);
    v_idx     JSONB;
    v_lbl     JSONB := '{}'::jsonb;
    v_period  TEXT;
    v_from    TEXT;
    v_to      TEXT;
    v_ps      DATE;
    v_pe      DATE;
    v_row     JSONB;
    v_n       INT;
    v_c       INT;
    v_cell    TEXT;
    v_val     TEXT;
    v_arr     JSONB[] := '{}';
    v_d       DATE;
    v_in      NUMERIC;
    v_out     NUMERIC;
    v_bal     NUMERIC;
    v_prev    NUMERIC;
    v_typ     TEXT;
    v_key     TEXT;
    v_kind    TEXT;
    v_sub     TEXT;
    v_info    INT := 0;
    v_sum_in  NUMERIC := 0;
    v_sum_out NUMERIC := 0;
    v_desc    BOOLEAN;
    v_e       JSONB;
    v_rows    JSONB;
BEGIN
    SELECT pr INTO v_prof FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr WHERE pr->>'key' = 'bondora_go_grow_v1';
    v_idx := p->'columns';

    -- Kopfblock: Label -> naechste nicht leere Zelle rechts daneben; der Zeitraum steht als eigene Zelle
    FOR v_row IN SELECT r FROM jsonb_array_elements(COALESCE(p->'preamble', '[]'::jsonb)) r WHERE jsonb_typeof(r) = 'array' LOOP
        FOR v_c IN 0 .. jsonb_array_length(v_row) - 1 LOOP
            v_cell := lower(btrim(v_row->>v_c));
            v_cell := CASE v_cell WHEN 'zu beginn' THEN 'opening' WHEN 'einzahlungen' THEN 'payments in'
                                  WHEN 'auszahlungen' THEN 'payments out' WHEN 'ergebnis' THEN 'closing' ELSE v_cell END;
            IF v_cell IN ('opening', 'payments in', 'payments out', 'closing') THEN
                SELECT btrim(x) INTO v_val FROM jsonb_array_elements_text(v_row) WITH ORDINALITY AS y(x, o)
                WHERE o > v_c + 1 AND btrim(x) <> '' ORDER BY o LIMIT 1;
                IF pg_input_is_valid(v_val, 'numeric') THEN
                    v_lbl := v_lbl || jsonb_build_object(v_cell, round(v_val::numeric, 2));
                END IF;
                v_val := NULL;
            ELSIF v_cell ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4} *- *[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$'
               OR v_cell ~ '^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4} *- *[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}$' THEN
                v_period := v_cell;
            END IF;
        END LOOP;
    END LOOP;
    IF v_period IS NULL OR NOT (v_lbl ?& ARRAY['opening', 'payments in', 'payments out', 'closing']) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_invalid',
            'reason', 'The Bondora statement has no summary block (period, opening, payments in/out, closing) - export the account statement again.');
    END IF;
    v_from := btrim(split_part(v_period, '-', 1));
    v_to   := btrim(split_part(v_period, '-', 2));
    v_ps := CASE WHEN v_from LIKE '%/%'
                 THEN make_date(split_part(v_from, '/', 3)::int, split_part(v_from, '/', 1)::int, split_part(v_from, '/', 2)::int)
                 ELSE make_date(split_part(v_from, '.', 3)::int, split_part(v_from, '.', 2)::int, split_part(v_from, '.', 1)::int) END;
    v_pe := CASE WHEN v_to LIKE '%/%'
                 THEN make_date(split_part(v_to, '/', 3)::int, split_part(v_to, '/', 1)::int, split_part(v_to, '/', 2)::int)
                 ELSE make_date(split_part(v_to, '.', 3)::int, split_part(v_to, '.', 2)::int, split_part(v_to, '.', 1)::int) END;
    IF v_ps > v_pe THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_invalid',
            'reason', 'The printed period of the Bondora statement ends before it starts - export the account statement again.');
    END IF;

    -- Zeilen lesen
    FOR v_row, v_n IN SELECT e, (o)::int FROM jsonb_array_elements(p->'rows') WITH ORDINALITY AS x(e, o) LOOP
        CONTINUE WHEN jsonb_typeof(v_row) <> 'array'
            OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_row) c WHERE btrim(c) <> '');
        v_cell := btrim(v_row->>((v_idx->>'date')::int));
        v_d := CASE WHEN v_cell ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(v_cell, 10)::date
                    WHEN v_cell ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$'
                    THEN make_date(split_part(v_cell, '/', 3)::int, split_part(v_cell, '/', 1)::int, split_part(v_cell, '/', 2)::int)
                    WHEN v_cell ~ '^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}$'
                    THEN make_date(split_part(v_cell, '.', 3)::int, split_part(v_cell, '.', 2)::int, split_part(v_cell, '.', 1)::int) END;
        v_in  := CASE WHEN pg_input_is_valid(btrim(v_row->>((v_idx->>'in')::int)), 'numeric') THEN round(btrim(v_row->>((v_idx->>'in')::int))::numeric, 2) END;
        v_out := CASE WHEN pg_input_is_valid(btrim(v_row->>((v_idx->>'out')::int)), 'numeric') THEN round(btrim(v_row->>((v_idx->>'out')::int))::numeric, 2) END;
        v_bal := CASE WHEN pg_input_is_valid(btrim(v_row->>((v_idx->>'balance')::int)), 'numeric') THEN round(btrim(v_row->>((v_idx->>'balance')::int))::numeric, 2) END;
        IF v_d IS NULL OR v_bal IS NULL
           OR (NULLIF(btrim(v_row->>((v_idx->>'in')::int)), '') IS NOT NULL AND v_in IS NULL)
           OR (NULLIF(btrim(v_row->>((v_idx->>'out')::int)), '') IS NOT NULL AND v_out IS NULL) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', v_n + v_hrow,
                'reason', 'Row ' || (v_n + v_hrow) || ' has no readable date, amount or balance.');
        END IF;
        IF v_d NOT BETWEEN v_ps AND v_pe THEN
            RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', v_n + v_hrow,
                'reason', 'Row ' || (v_n + v_hrow) || ' lies outside the printed period - export the account statement again.');
        END IF;
        v_in := COALESCE(v_in, 0);
        v_out := COALESCE(v_out, 0);
        v_typ := btrim(v_row->>((v_idx->>'payment type')::int));
        -- deutsche Export-Variante -> englischer Typ-Schluessel (Text bleibt im Original fuer Karte/name)
        v_key := CASE lower(v_typ) WHEN 'go & grow zinsen' THEN 'go & grow returns'
                                   WHEN 'sepa-banküberweisung' THEN 'sepa payment'
                                   WHEN 'abheben auf bankkonto' THEN 'withdrawal to bank account'
                                   ELSE lower(v_typ) END;
        v_sub := NULL;
        v_kind := CASE
            WHEN v_key = 'go & grow returns' THEN 'interest'
            WHEN v_key LIKE 'unallocated balance%' THEN 'info'
            WHEN v_key = 'sepa payment' AND v_out = 0 THEN 'cash'
            WHEN v_key = 'withdrawal to bank account' AND v_in = 0 THEN 'cash'
            ELSE 'unknown' END;
        IF v_kind = 'cash' THEN
            v_sub := CASE WHEN v_key = 'withdrawal to bank account' THEN 'withdrawal'
                          WHEN v_in < (v_prof->>'small_inflow_max')::numeric THEN 'legacy_return'
                          ELSE 'deposit' END;
        END IF;
        v_arr := v_arr || jsonb_build_object('row_no', v_n + v_hrow, 'date', v_d, 'kind', v_kind, 'sub_kind', v_sub,
            'cash_amount', v_in - v_out, 'in', v_in, 'out', v_out, 'balance', v_bal,
            -- Gebuehr nur, wenn nach ihr noch ein Transfer bleibt (eine Auszahlung <= Gebuehr gibt es bei Bondora nicht)
            'transfer_fee', CASE WHEN v_sub = 'withdrawal' AND v_out > (v_prof->>'withdrawal_fee')::numeric
                                 THEN (v_prof->>'withdrawal_fee')::numeric END,
            'name', v_typ, 'purpose', v_typ, 'type', v_typ,
            'reason', CASE WHEN v_kind = 'unknown' THEN 'unsupported_type' END);
    END LOOP;
    v_rows := to_jsonb(v_arr);

    -- laufender Saldo in Datumsfolge (absteigende Datei -> umgekehrt pruefen)
    v_desc := jsonb_array_length(v_rows) > 1
              AND (v_rows->0->>'date')::date > (v_rows->(jsonb_array_length(v_rows) - 1)->>'date')::date;
    v_prev := (v_lbl->>'opening')::numeric;
    FOR v_e IN SELECT e FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS x(e, o)
               ORDER BY CASE WHEN v_desc THEN -o ELSE o END LOOP
        IF v_e->>'kind' = 'info' THEN
            IF (v_e->>'balance')::numeric <> v_prev THEN
                RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', (v_e->>'row_no')::int,
                    'reason', 'Row ' || (v_e->>'row_no') || ' (' || (v_e->>'type') || ') changes the balance - the export layout changed.');
            END IF;
            v_info := v_info + 1;
            CONTINUE;
        END IF;
        IF v_prev + (v_e->>'cash_amount')::numeric <> (v_e->>'balance')::numeric THEN
            RETURN jsonb_build_object('ok', false, 'code', 'export_invalid', 'row_no', (v_e->>'row_no')::int,
                'reason', 'Row ' || (v_e->>'row_no') || ': the running balance does not add up - the export is incomplete or changed.');
        END IF;
        v_prev := (v_e->>'balance')::numeric;
        v_sum_in := v_sum_in + (v_e->>'in')::numeric;
        v_sum_out := v_sum_out + (v_e->>'out')::numeric;
    END LOOP;
    IF v_prev <> (v_lbl->>'closing')::numeric OR v_sum_in <> (v_lbl->>'payments in')::numeric
       OR v_sum_out <> (v_lbl->>'payments out')::numeric THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_invalid',
            'reason', 'Opening balance plus the rows does not give the printed closing balance (or the printed payments in/out) - the export is incomplete.');
    END IF;

    RETURN jsonb_build_object('ok', true,
        'rows', (SELECT COALESCE(jsonb_agg(e - 'in' - 'out' - 'balance' ORDER BY (e->>'row_no')::int), '[]'::jsonb)
                 FROM jsonb_array_elements(v_rows) e WHERE e->>'kind' <> 'info'),
        'unknown_rows', (SELECT COALESCE(jsonb_agg(jsonb_build_object('row_no', e->'row_no', 'date', e->'date', 'type', e->'type',
                             'cash_amount', e->'cash_amount', 'name', e->'name', 'reason', e->'reason') ORDER BY (e->>'row_no')::int), '[]'::jsonb)
                         FROM jsonb_array_elements(v_rows) e WHERE e->>'kind' = 'unknown'),
        'info_count', v_info,
        'statement', jsonb_build_object('period_start', v_ps, 'period_end', v_pe,
                                        'opening_balance', (v_lbl->>'opening')::numeric, 'closing_balance', (v_lbl->>'closing')::numeric),
        'legacy_return_label', v_prof->>'legacy_return_label',
        'account_types', '[]'::jsonb, 'currencies', '[]'::jsonb);
END;
$$;
