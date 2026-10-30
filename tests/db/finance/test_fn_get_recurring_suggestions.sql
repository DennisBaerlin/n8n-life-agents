-- ============================================================
-- test_fn_get_recurring_suggestions -- wiederkehrende Zahlungen aus einem Bank-Export erkennen ("Import zuerst")
--   finance.fn_get_recurring_suggestions (READ): Export -> Reihen (Schluessel IBAN bzw. Name, Betrags-Cluster, Rhythmus,
--   Reife/Aktualitaet) -> Bekannt-Filter -> Vorschlaege im Format der Write-Tools. Alle Namen/IBANs frei erfunden
--   (gueltige Pruefziffern). Termine relativ zu heute (pg_temp.due), so gewaehlt, dass sie immer in der Vergangenheit liegen.
--   S1 Miete am 1. (einmal am 3., einmal am 30. des Vormonats gebucht); S2 Abo mit Preisstufe 9,99 -> 13,99 = EINE Reihe;
--   S3 zwei Abos ueber dieselbe Zahlungsdienst-IBAN, eines bekannt (IBAN-Schluessel + Betrag) -> nur das andere;
--   S4 Gehalt am Monatsletzten, schwankend, plus Sonderzahlung (Ausreisser); S5 Kindergeld ohne IBAN (Name);
--   S6 vierteljaehrlicher Beitrag (2 Vorkommen); S7 Uebertrag auf ein eigenes Konto; S8 Haushaltsmitglied ohne eigenes
--   Konto; S9 Karten-Abo mit Ziffern-Fragmenten im Namen; S10 Einkaeufe ohne Muster -> nichts; S11 beendetes Abo -> nichts;
--   S12 bekannt per exaktem Betrag (anderer Name); S13 bekannt per Name + Betrag; S14 bekannt auf einem anderen Konto ->
--   known_elsewhere; S15 beendeter Dauerauftrag (valid_to vorbei) zaehlt nicht; S16 woechentlich; S17 jaehrlich;
--   R1 Startdatum nach dem Abgleich-Tag; R2 Rundlauf: angelegt mit IBAN -> nicht mehr vorgeschlagen, Monats-Check Stufe A;
--   S18 gleicher Betrag wie ein erfasster Dauerauftrag, anderer Tag -> neu; S19 zwei Zahlungen am selben Tag -> Summe;
--   R3 Datei unter ~3 Monaten -> nur Hinweis; R4 Trade-Republic-Export (Name aus dem Buchungstext ohne Ziffern), Zins nie.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.n26(p_d date, p_partner text, p_iban text, p_typ text, p_amt numeric)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text, p_d::text, p_partner, p_iban, p_typ, '', 'Hauptkonto', p_amt::text, '', '', '');
$$;
-- due(0, dom) = der juengste Tag dom, der mindestens 4 Tage zurueckliegt (immer in [heute-34, heute-4]: Buchung +-3 Tage
-- bleibt in der Vergangenheit und juenger als 1,5 Monate); k Monate frueher; dom -1 = Monatsletzter.
CREATE FUNCTION pg_temp.due(p_k int, p_dom int)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_dom = -1
                THEN (date_trunc('month', core.fn_today() - 3) - make_interval(months => p_k))::date - 1
                ELSE (date_trunc('month', core.fn_today() - 4 - (p_dom - 1)) - make_interval(months => p_k))::date + (p_dom - 1) END;
$$;
CREATE FUNCTION pg_temp.sug(p_res jsonb, p_like text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT s FROM jsonb_array_elements(p_res->'suggestions') s WHERE s->>'name' ILIKE p_like LIMIT 1;
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["Booking Date","Value Date","Partner Name","Partner Iban","Type","Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"]';
    c_rent CONSTANT TEXT := 'DE89370400440532013000';
    c_job  CONSTANT TEXT := 'DE02120300000000202051';
    c_pay  CONSTANT TEXT := 'DE02500105170137075030';
    c_tg   CONSTANT TEXT := 'DE02100100100006820101';
    c_hh   CONSTANT TEXT := 'DE34200400000123456789';
    v_rows JSONB := '[]'::jsonb;
    v_n26  INT; v_tg INT; v_dkb INT; v_rp INT;
    v_p    JSONB;
    v_res  JSONB;
    v_s    JSONB;
    v_m    JSONB;
    k      INT;
BEGIN
    UPDATE finance.accounts SET status = 'closed' WHERE finance.fn_bank_export_account_profile(id) IS NOT NULL;
    INSERT INTO agent.persons (person_id, full_name, role) VALUES ('rs_erika', 'Erika Zweistein', 'partner');
    v_n26 := (finance.fn_create_account(jsonb_build_object('name', '__t_rs_n26__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'N26', 'opening_balance', 1000, 'opening_balance_date', (T - 500)::text))->>'account_id')::int;
    v_tg  := (finance.fn_create_account(jsonb_build_object('name', '__t_rs_tg__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'account_number', c_tg, 'opening_balance', 0, 'opening_balance_date', (T - 500)::text))->>'account_id')::int;
    v_dkb := (finance.fn_create_account(jsonb_build_object('name', '__t_rs_dkb__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'DKB', 'opening_balance', 0, 'opening_balance_date', (T - 500)::text))->>'account_id')::int;
    IF v_n26 IS NULL OR v_tg IS NULL OR v_dkb IS NULL THEN RAISE EXCEPTION 'SETUP accounts'; END IF;

    -- ---------- bestehende Dauerauftraege (Bekannt-Filter) ----------
    -- S3: Hoerbuch ueber den Zahlungsdienst, IBAN-Schluessel gelernt
    v_rp := (finance.fn_create_recurring_payment(jsonb_build_object('name', 'Hoerbuch', 'account_id', v_n26, 'direction', 'expense',
                 'amount', 4.99, 'schedule_unit', 'month', 'schedule_day_of_month', 3, 'first_payment_date', (T - 400)::text))->>'recurring_payment_id')::int;
    INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value) VALUES (v_rp, 'counterparty_iban', c_pay);
    -- S12: Haftpflicht unter eigenem Namen, Bank druckt den Versicherer
    PERFORM finance.fn_create_recurring_payment(jsonb_build_object('name', 'Haftpflicht', 'account_id', v_n26, 'direction', 'expense',
                 'amount', 6.50, 'schedule_unit', 'month', 'schedule_day_of_month', 11, 'first_payment_date', (T - 400)::text));
    -- S13: Fitnessstudio, Bank bucht 42,00 statt 39,90 (Name + Betrag +-7,5 %)
    PERFORM finance.fn_create_recurring_payment(jsonb_build_object('name', 'Fitnessstudio', 'account_id', v_n26, 'direction', 'expense',
                 'amount', 39.90, 'schedule_unit', 'month', 'schedule_day_of_month', 4, 'first_payment_date', (T - 400)::text));
    -- S14: Zeitung ist beim DKB-Konto erfasst
    PERFORM finance.fn_create_recurring_payment(jsonb_build_object('name', 'Zeitung', 'account_id', v_dkb, 'direction', 'expense',
                 'amount', 19.90, 'schedule_unit', 'month', 'schedule_day_of_month', 13, 'first_payment_date', (T - 400)::text));
    -- S15: Kinoabo lief aus (valid_to vorbei) -> zaehlt nicht mehr
    PERFORM finance.fn_create_recurring_payment(jsonb_build_object('name', 'Kinoabo', 'account_id', v_n26, 'direction', 'expense',
                 'amount', 9.99, 'schedule_unit', 'month', 'schedule_day_of_month', 7, 'first_payment_date', (T - 400)::text,
                 'valid_to', (T - 300)::text));
    -- S18: Videodienst 11,99 am 5. erfasst - ein anderes Abo mit gleichem Betrag am 20. ist NICHT bekannt (Review)
    PERFORM finance.fn_create_recurring_payment(jsonb_build_object('name', 'Videodienst', 'account_id', v_n26, 'direction', 'expense',
                 'amount', 11.99, 'schedule_unit', 'month', 'schedule_day_of_month', 5, 'first_payment_date', (T - 400)::text));

    -- ---------- Export (6 Monate, S16 woechentlich, S17 jaehrlich -> 13 Monate Spanne) ----------
    FOR k IN 0..5 LOOP
        -- S1 Miete am 1.: k=1 am 3., k=2 am 30. des Vormonats
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 1) + CASE k WHEN 1 THEN 2 WHEN 2 THEN -2 ELSE 0 END,
                      'Vermieter Test', c_rent, 'Debit Transfer', -850));
        -- S2 Abo 9,99 -> 13,99
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 12), 'Musikdienst Test', '', 'Presentment',
                      CASE WHEN k >= 3 THEN -9.99 ELSE -13.99 END));
        -- S3 zwei Abos ueber den Zahlungsdienst
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 3), 'Zahldienst Europe', c_pay, 'Direct Debit', -4.99));
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 10), 'Zahldienst Europe', c_pay, 'Direct Debit', -17.99));
        -- S4 Gehalt am Monatsletzten, schwankend
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, -1), 'Arbeitgeber Test GmbH', c_job, 'Credit Transfer',
                      (ARRAY[3150, 3080, 3100, 3120, 3090, 3100])[k + 1]));
        -- S5 Kindergeld ohne IBAN, Tag 7..9
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 8) + (k % 3) - 1, 'Familienkasse Test', '', 'Credit Transfer', 255));
        -- S7 Uebertrag aufs eigene Tagesgeld
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 2), 'Max Zweistein', c_tg, 'Debit Transfer', -200));
        -- S8 an ein Haushaltsmitglied (kein eigenes Konto mit dieser IBAN)
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 14), 'Erika Zweistein', c_hh, 'Debit Transfer', -150));
        -- S9 Karten-Abo, Ziffern-Fragment wechselt
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 6),
                      'STREAMFLIX.COM ' || CASE WHEN k % 2 = 0 THEN '0815' ELSE '4711' END, '', 'Presentment', -13.99));
        -- S10 Einkaeufe ohne Muster
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 5 + k), 'Supermarkt Test 0042', '', 'Presentment',
                      (ARRAY[-23.45, -67.80, -12.10, -45.00, -31.75, -88.20])[k + 1]));
        -- S11 Altabo endete vor drei Monaten
        IF k >= 3 THEN
            v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 9), 'Altabo Test', '', 'Direct Debit', -7.99));
        END IF;
        -- S12 Versicherer, S13 Fitnessstudio, S14 Zeitung, S15 Kinoabo
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 11), 'Versicherung Test AG', '', 'Direct Debit', -6.50));
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 4), 'FITNESSSTUDIO Muskel', '', 'Direct Debit', -42.00));
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 13), 'Zeitung Test Verlag', '', 'Direct Debit', -19.90));
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 7), 'Kinoabo Test', '', 'Direct Debit', -9.99));
        -- S18 gleicher Betrag wie Videodienst, anderer Tag; S19 zwei Kita-Beitraege am selben Tag
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 20), 'Hoerdienst Test', '', 'Direct Debit', -11.99));
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(k, 1), 'Kita Test', '', 'Direct Debit', -200),
                                              pg_temp.n26(pg_temp.due(k, 1), 'Kita Test', '', 'Direct Debit', -200));
    END LOOP;
    -- S4 Sonderzahlung mitten im Monat (Ausreisser derselben Reihe)
    v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(2, 15), 'Arbeitgeber Test GmbH', c_job, 'Credit Transfer', 1500));
    -- S6 Vereinsbeitrag vierteljaehrlich
    v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(1, 15), 'Sportverein Test e.V.', '', 'Direct Debit', -30));
    v_rows := v_rows || jsonb_build_array(pg_temp.n26(pg_temp.due(4, 15), 'Sportverein Test e.V.', '', 'Direct Debit', -30));
    -- S16 Wochenmarkt woechentlich
    FOR k IN 0..9 LOOP
        v_rows := v_rows || jsonb_build_array(pg_temp.n26(T - 3 - 7 * k, 'Wochenmarkt Test', '', 'Presentment', -12));
    END LOOP;
    -- S17 jaehrlich
    v_rows := v_rows || jsonb_build_array(pg_temp.n26(T - 30, 'Kfz-Steuer Test', '', 'Direct Debit', -120));
    v_rows := v_rows || jsonb_build_array(pg_temp.n26((T - 30 - interval '1 year')::date, 'Kfz-Steuer Test', '', 'Direct Debit', -120));

    v_p := jsonb_build_object('table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows));
    v_res := finance.fn_get_recurring_suggestions(v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'account_name' IS DISTINCT FROM '__t_rs_n26__'
       OR v_res ? 'hint' OR (v_res->>'span_days')::int < 365 THEN
        RAISE EXCEPTION 'FAIL [G0 ok, Konto, Spanne]: %', v_res;
    END IF;

    -- S1 Miete
    v_s := pg_temp.sug(v_res, 'Vermieter Test');
    IF v_s IS NULL OR v_s->>'kind' <> 'payment' OR v_s->>'direction' <> 'expense' OR (v_s->>'amount')::numeric <> 850
       OR v_s->>'schedule_unit' <> 'month' OR (v_s->>'schedule_interval')::int <> 1 OR (v_s->>'schedule_day_of_month')::int <> 1
       OR (v_s->>'first_payment_date')::date <> pg_temp.due(-1, 1) OR (v_s->>'occurrences')::int <> 6
       OR v_s->>'counterparty_iban' <> c_rent OR (v_s->>'amount_varies')::boolean THEN
        RAISE EXCEPTION 'FAIL [S1 Miete am 1.]: %', v_s;
    END IF;
    -- S2 Preisstufe = eine Reihe, neuester Betrag
    v_s := pg_temp.sug(v_res, 'Musikdienst Test');
    IF v_s IS NULL OR (v_s->>'amount')::numeric <> 13.99 OR (v_s->>'occurrences')::int <> 6
       OR NOT (v_s->>'amount_varies')::boolean OR (v_s->>'schedule_day_of_month')::int <> 12 OR v_s ? 'counterparty_iban' THEN
        RAISE EXCEPTION 'FAIL [S2 Preisstufe]: %', v_s;
    END IF;
    -- S3 nur das unbekannte Abo des Zahlungsdienstes
    IF (SELECT count(*) FROM jsonb_array_elements(v_res->'suggestions') s WHERE s->>'name' = 'Zahldienst Europe') <> 1
       OR (pg_temp.sug(v_res, 'Zahldienst Europe')->>'amount')::numeric <> 17.99
       -- geteilte IBAN (zwei Reihen) -> kein Schluessel im Vorschlag
       OR pg_temp.sug(v_res, 'Zahldienst Europe') ? 'counterparty_iban' THEN
        RAISE EXCEPTION 'FAIL [S3 Zahlungsdienst: 4,99 bekannt, 17,99 neu]: %', v_res->'suggestions';
    END IF;
    -- S4 Gehalt
    v_s := pg_temp.sug(v_res, 'Arbeitgeber Test GmbH');
    IF v_s IS NULL OR v_s->>'direction' <> 'income' OR (v_s->>'amount')::numeric <> 3150 OR (v_s->>'schedule_day_of_month')::int <> -1
       OR (v_s->>'occurrences')::int <> 6 OR (v_s->>'average_amount')::numeric <> 3106.67 OR NOT (v_s->>'amount_varies')::boolean
       OR (v_s->>'first_payment_date')::date <> pg_temp.due(-1, -1) THEN
        RAISE EXCEPTION 'FAIL [S4 Gehalt Monatsletzter, Ausreisser]: %', v_s;
    END IF;
    IF v_res->'suggestions'->0->>'name' <> 'Arbeitgeber Test GmbH' THEN
        RAISE EXCEPTION 'FAIL [S4 Sortierung nach Monatsbetrag]: %', v_res->'suggestions'->0;
    END IF;
    -- S5 Kindergeld (Name-Schluessel)
    v_s := pg_temp.sug(v_res, 'Familienkasse Test');
    IF v_s IS NULL OR v_s->>'direction' <> 'income' OR (v_s->>'amount')::numeric <> 255 OR (v_s->>'schedule_day_of_month')::int <> 8 THEN
        RAISE EXCEPTION 'FAIL [S5 Kindergeld]: %', v_s;
    END IF;
    -- S6 vierteljaehrlich
    v_s := pg_temp.sug(v_res, 'Sportverein Test e.V.');
    IF v_s IS NULL OR v_s->>'schedule_unit' <> 'month' OR (v_s->>'schedule_interval')::int <> 3
       OR (v_s->>'schedule_day_of_month')::int <> 15 OR (v_s->>'first_payment_date')::date <> pg_temp.due(-2, 15) THEN
        RAISE EXCEPTION 'FAIL [S6 vierteljaehrlich]: %', v_s;
    END IF;
    -- S7 Uebertrag
    SELECT s INTO v_s FROM jsonb_array_elements(v_res->'suggestions') s WHERE s->>'kind' = 'transfer';
    IF v_s IS NULL OR v_s->>'from_account' <> '__t_rs_n26__' OR v_s->>'to_account' <> '__t_rs_tg__'
       OR (v_s->>'amount')::numeric <> 200 OR (v_s->>'schedule_day_of_month')::int <> 2 THEN
        RAISE EXCEPTION 'FAIL [S7 Uebertrag eigenes Konto]: %', v_s;
    END IF;
    -- S8 Haushaltsmitglied
    v_s := pg_temp.sug(v_res, 'Erika Zweistein');
    IF v_s IS NULL OR v_s->>'kind' <> 'household' OR (v_s->>'amount')::numeric <> 150 THEN
        RAISE EXCEPTION 'FAIL [S8 Haushalt]: %', v_s;
    END IF;
    -- S9 Karten-Abo, Name = Originalschreibweise der letzten Zeile
    v_s := pg_temp.sug(v_res, 'STREAMFLIX.COM%');
    IF v_s IS NULL OR v_s->>'name' <> 'STREAMFLIX.COM 0815' OR (v_s->>'occurrences')::int <> 6 THEN
        RAISE EXCEPTION 'FAIL [S9 Ziffern-Fragmente]: %', v_s;
    END IF;
    -- S10-S14 nichts
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'suggestions') s
               WHERE s->>'name' IN ('Supermarkt Test 0042', 'Altabo Test', 'Versicherung Test AG', 'FITNESSSTUDIO Muskel',
                                    'Zeitung Test Verlag')) THEN
        RAISE EXCEPTION 'FAIL [S10-S14 kein Vorschlag]: %', v_res->'suggestions';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'known_elsewhere') e
                   WHERE e->>'name' = 'Zeitung Test Verlag' AND e->>'account_name' = '__t_rs_dkb__') THEN
        RAISE EXCEPTION 'FAIL [S14 known_elsewhere]: %', v_res->'known_elsewhere';
    END IF;
    -- S15 beendeter Dauerauftrag zaehlt nicht
    IF pg_temp.sug(v_res, 'Kinoabo Test') IS NULL THEN
        RAISE EXCEPTION 'FAIL [S15 valid_to vorbei -> wieder vorgeschlagen]: %', v_res->'suggestions';
    END IF;
    -- S16 woechentlich
    v_s := pg_temp.sug(v_res, 'Wochenmarkt Test');
    IF v_s IS NULL OR v_s->>'schedule_unit' <> 'week' OR (v_s->>'schedule_interval')::int <> 1 OR v_s->>'schedule_day_of_month' IS NOT NULL
       OR (v_s->>'first_payment_date')::date <> T + 4 THEN
        RAISE EXCEPTION 'FAIL [S16 woechentlich]: %', v_s;
    END IF;
    -- S17 jaehrlich
    v_s := pg_temp.sug(v_res, 'Kfz-Steuer Test');
    IF v_s IS NULL OR v_s->>'schedule_unit' <> 'year' OR (v_s->>'schedule_interval')::int <> 1
       OR (v_s->>'first_payment_date')::date <> (T - 30 + interval '1 year')::date THEN
        RAISE EXCEPTION 'FAIL [S17 jaehrlich]: %', v_s;
    END IF;
    -- S18 gleicher Betrag, anderer Tag -> neu; S19 zwei Zahlungen am selben Tag -> ein Termin mit der Summe
    IF pg_temp.sug(v_res, 'Hoerdienst Test') IS NULL THEN
        RAISE EXCEPTION 'FAIL [S18 gleicher Betrag anderer Tag -> vorgeschlagen]: %', v_res->'suggestions';
    END IF;
    v_s := pg_temp.sug(v_res, 'Kita Test');
    IF v_s IS NULL OR (v_s->>'amount')::numeric <> 400 OR (v_s->>'occurrences')::int <> 6 OR (v_s->>'schedule_day_of_month')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [S19 selber Tag -> Summe]: %', v_s;
    END IF;
    IF jsonb_array_length(v_res->'suggestions') <> 14 THEN
        RAISE EXCEPTION 'FAIL [G1 genau 14 Vorschlaege]: %', (SELECT jsonb_agg(s->>'name') FROM jsonb_array_elements(v_res->'suggestions') s);
    END IF;
    RAISE NOTICE 'PASS [S1-S17 Erkennung + Bekannt-Filter]';

    -- ---------- R1 Startdatum nach dem bestaetigten Abgleich-Tag ----------
    UPDATE finance.accounts SET last_reconciled_at = pg_temp.due(-1, 8) WHERE id = v_n26;
    v_s := pg_temp.sug(finance.fn_get_recurring_suggestions(v_p), 'Familienkasse Test');
    IF (v_s->>'first_payment_date')::date <> pg_temp.due(-2, 8) THEN
        RAISE EXCEPTION 'FAIL [R1 Start nach last_reconciled_at]: %', v_s;
    END IF;
    UPDATE finance.accounts SET last_reconciled_at = NULL WHERE id = v_n26;
    RAISE NOTICE 'PASS [R1 Startdatum nach Abgleich]';

    -- ---------- R2 Rundlauf: anlegen mit IBAN -> nicht mehr vorgeschlagen; Monats-Check trifft per Schluessel ----------
    v_s := pg_temp.sug(v_res, 'Vermieter Test');
    v_m := finance.fn_create_recurring_payment(jsonb_build_object('name', 'Miete', 'account_id', v_n26, 'direction', 'expense',
               'amount', v_s->'amount', 'schedule_unit', v_s->>'schedule_unit', 'schedule_interval', v_s->'schedule_interval',
               'schedule_day_of_month', v_s->'schedule_day_of_month', 'first_payment_date', v_s->>'first_payment_date',
               'counterparty_iban', v_s->>'counterparty_iban'));
    IF (v_m->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [R2 anlegen]: %', v_m; END IF;
    IF pg_temp.sug(finance.fn_get_recurring_suggestions(v_p), 'Vermieter Test') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [R2 angelegt -> nicht mehr vorgeschlagen]';
    END IF;
    -- Mieterhoehung um 6 %: Stufe B (exakt bzw. +-5 % mit Namens-Token) greift nicht, der IBAN-Schluessel schon
    v_m := finance.fn_statement_match(v_n26, (v_s->>'first_payment_date')::date - 5, (v_s->>'first_payment_date')::date + 5,
               jsonb_build_array(jsonb_build_object('date', v_s->>'first_payment_date', 'amount', -901,
                                                    'counterparty', 'Vermieter Test', 'counterparty_iban', c_rent)));
    IF v_m->'matched'->0->>'stage' IS DISTINCT FROM 'A' THEN
        RAISE EXCEPTION 'FAIL [R2 Monats-Check Stufe A]: %', v_m;
    END IF;
    RAISE NOTICE 'PASS [R2 Rundlauf]';

    -- ---------- R3 Datei unter ~3 Monaten ----------
    v_res := finance.fn_get_recurring_suggestions(jsonb_build_object('table', jsonb_build_object('rows', jsonb_build_array(v_hdr,
                 pg_temp.n26(T - 60, 'Testdienst', '', 'Direct Debit', -5), pg_temp.n26(T - 30, 'Testdienst', '', 'Direct Debit', -5),
                 pg_temp.n26(T - 1, 'Testdienst', '', 'Direct Debit', -5)))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'hint' IS DISTINCT FROM 'export_too_short'
       OR jsonb_array_length(v_res->'suggestions') <> 0 THEN
        RAISE EXCEPTION 'FAIL [R3 zu kurz -> nur Hinweis]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [R3 export_too_short]';

    -- ---------- R5 Export endete vor gut einem Monat: Monatszahlung bleibt (aktiv = gemessen am Dateiende) ----------
    v_res := finance.fn_get_recurring_suggestions(jsonb_build_object('table', jsonb_build_object('rows', jsonb_build_array(v_hdr) ||
                 (SELECT jsonb_agg(pg_temp.n26((T - 40 - make_interval(months => g.m))::date, 'Gartenservice Test', '', 'Direct Debit', -35))
                  FROM generate_series(0, 4) g(m)))));
    IF pg_temp.sug(v_res, 'Gartenservice Test') IS NULL OR v_res ? 'hint' THEN
        RAISE EXCEPTION 'FAIL [R5 Dateiende vor 40 Tagen -> Vorschlag bleibt]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [R5 aktiv ab Dateiende]';
END $$;

-- ---------- R4 Trade Republic: Karten-Abo ja, Zinszeilen nie ----------
CREATE FUNCTION pg_temp.tr(p_d date, p_typ text, p_amt numeric, p_desc text, p_id text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text || 'T10:00:00Z', p_d::text, 'DEFAULT', 'CASH', p_typ, '', '', '', '',
                             '', p_amt::text, '', '', 'EUR', '', '', '', p_desc, p_id, '', '', '', '');
$$;
DO $$
DECLARE
    T     DATE := core.fn_today();
    v_hdr JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_rows JSONB := '[]'::jsonb;
    v_res JSONB;
    k     INT;
BEGIN
    UPDATE finance.accounts SET status = 'closed' WHERE finance.fn_bank_export_account_profile(id) IS NOT NULL;
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_rs_tr__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 100, 'opening_balance_date', (T - 400)::text));
    FOR k IN 0..5 LOOP
        v_rows := v_rows || jsonb_build_array(pg_temp.tr(pg_temp.due(k, 9), 'CARD_TRANSACTION', -2.99, 'Testcloud Speicher 0815 4711', 'c-' || k));
        v_rows := v_rows || jsonb_build_array(pg_temp.tr(pg_temp.due(k, 1), 'INTEREST_PAYMENT', 3.21, 'Zinsen', 'i-' || k));
    END LOOP;
    v_res := finance.fn_get_recurring_suggestions(jsonb_build_object('table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows)));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_res->'suggestions') <> 1
       OR v_res->'suggestions'->0->>'name' <> 'Testcloud Speicher' OR (v_res->'suggestions'->0->>'amount')::numeric <> 2.99 THEN
        RAISE EXCEPTION 'FAIL [R4 TR: Karte ja (Name ohne Ziffern-Woerter), Zins nie]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [R4 Trade Republic]';
END $$;
ROLLBACK;
