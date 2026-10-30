-- ============================================================
-- test_bank_statement_n26 -- Monats-Check aus dem N26-CSV-Export (Profil n26_v1)
--   fn_statement_prepare (source:'file') + fn_apply_bank_statement ueber den N26-Leser. Werte erfunden, Daten relativ
--   zu core.fn_today(). Szenario: N26-Girokonto (Start 1000, Stichtag heute-20), eigenes Tagesgeld (IBAN als Kontonummer),
--   Go&Grow-Konto mit dem N26-Konto als Verrechnungskonto. Export: Gehalt +2000, Ueberweisung -300 an die eigene IBAN
--   (Stufe T), Karte -30, Auszahlung Bondora +200 ueber das Sammelkonto (Pool-Regel, 1 EUR Gebuehr beim Go&Grow),
--   Zeile vor dem Schnitt (ignoriert), Zeile von heute (after_period).
--   Danach: naechster Export mit einer verspaeteten Zeile und einem erst jetzt auftauchenden identischen Zwilling der
--   Karte -> genau diese zwei zaehlen (ext_ref), nichts doppelt, kein zweiter Transfer.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.n26_row(p_d date, p_partner text, p_iban text, p_type text, p_ref text, p_amt text,
                                p_space text DEFAULT 'Hauptkonto')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text, p_d::text, p_partner, p_iban, p_type, p_ref, p_space, p_amt, '', '', '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["Booking Date","Value Date","Partner Name","Partner Iban","Type","Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"]';
    v_n26  INT;
    v_tg   INT;
    v_gg   INT;
    v_rows JSONB;
    v_p    JSONB;
    v_res  JSONB;
    v_prep JSONB;
    v_app  JSONB;
BEGIN
    -- ---------- Setup ----------
    v_n26 := (finance.fn_create_account(jsonb_build_object('name', '__t_n26_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'N26', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_tg  := (finance.fn_create_account(jsonb_build_object('name', '__t_n26_tg__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'account_number', 'DE89370400440532013000',
                 'opening_balance', 100, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_gg  := (finance.fn_create_account(jsonb_build_object('name', '__t_n26_gg__', 'account_type', 'p2p', 'currency', 'EUR',
                 'bank', 'Bondora', 'settlement_id', v_n26,
                 'opening_balance', 600, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    IF v_n26 IS NULL OR v_tg IS NULL OR v_gg IS NULL THEN RAISE EXCEPTION 'SETUP accounts'; END IF;

    v_rows := jsonb_build_array(
        pg_temp.n26_row(T - 15, 'Testfirma GmbH', 'DE02120300000000202051', 'Credit Transfer', 'Gehalt', '2000.00'),
        pg_temp.n26_row(T - 12, 'Erika Muster', 'DE89 3704 0044 0532 0130 00', 'Debit Transfer', 'Sparen', '-300.00'),
        pg_temp.n26_row(T - 10, 'Baeckerei Test', '', 'Presentment', '', '-30'),
        pg_temp.n26_row(T - 8, 'Bondora Capital OU', 'EE382200221020145685', 'Credit Transfer', 'Erika Muster', '200.00'),
        pg_temp.n26_row(T, 'Kiosk Heute', '', 'Presentment', '', '-10'),
        pg_temp.n26_row(T - 25, 'Vor dem Schnitt', '', 'Presentment', '', '-99'));
    -- Zeitraum heute-19..gestern: 2000 - 300 - 30 + 200 = 1870 -> Stand gestern 2870, heute -10 -> App zeigt 2860
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_n26_giro__', 'closing_balance', '2.860,00',
                              'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows));

    -- ---------- Ablehnungen ohne Karte ----------
    v_res := finance.fn_statement_prepare(v_p - 'closing_balance');
    IF v_res->>'code' IS DISTINCT FROM 'closing_balance_required' OR v_res ? 'card_lines' THEN
        RAISE EXCEPTION 'FAIL [B1 Owner-Saldo Pflicht]: %', v_res;
    END IF;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array(v_hdr) || v_rows || jsonb_build_array(pg_temp.n26_row(T - 9, 'Test', '', 'Presentment', '', '-1', 'Reise')))));
    IF v_res->>'code' IS DISTINCT FROM 'multiple_sub_accounts' THEN RAISE EXCEPTION 'FAIL [B2 Spaces gemischt]: %', v_res; END IF;
    RAISE NOTICE 'PASS [B1-B2 Ablehnungen]';

    -- ---------- Vorschau ----------
    v_prep := finance.fn_statement_prepare(v_p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [B3 prepare ok]: %', v_prep; END IF;
    IF (v_prep->>'period_start')::date <> T - 19 OR (v_prep->>'period_end')::date <> T - 1
       OR (v_prep->>'closing_balance')::numeric <> 2870 OR (v_prep->>'after_period')::numeric <> -10
       OR (v_prep->>'drift')::numeric <> 0 OR (v_prep->>'lump')::numeric <> 1970 THEN
        RAISE EXCEPTION 'FAIL [B4 Zeitraum, Saldo, drift 0, Rest 1970]: %', v_prep;
    END IF;
    -- eigene IBAN -> Transfer zum Tagesgeld; Bondora-Sammelkonto -> Go&Grow mit 1 EUR Gebuehr dort
    IF (SELECT string_agg(((m->>'amount')::numeric)::int || ':' || (m->>'other_account_id') || ':' || COALESCE(m->>'partner_fee', '-'), ','
                          ORDER BY (m->>'line_date')::date)
        FROM jsonb_array_elements(v_prep->'matched') m)
       IS DISTINCT FROM '-300:' || v_tg || ':-,200:' || v_gg || ':1.00' THEN
        RAISE EXCEPTION 'FAIL [B5 Transfer per IBAN + Pool-Regel]: %', v_prep->'matched';
    END IF;
    IF jsonb_array_length(v_prep->'seen_refs') <> 4 OR (v_prep->>'late_count')::int <> 0
       OR jsonb_array_length(v_prep->'export_unknown') <> 0 THEN
        RAISE EXCEPTION 'FAIL [B6 seen_refs/late/unknown]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [B3-B6 Vorschau]';

    -- ---------- Buchung ----------
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [B7 apply]: %', v_app; END IF;
    IF (SELECT balance FROM finance.account_balances WHERE account_id = v_n26) <> 2870
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_tg) <> 400
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_gg) <> 399
       OR (SELECT last_reconciled_at FROM finance.accounts WHERE id = v_n26) <> T - 1
       OR (SELECT count(*) FROM finance.statement_seen_refs WHERE statement_id = (v_app->>'statement_id')::int) <> 4 THEN
        RAISE EXCEPTION 'FAIL [B8 Salden + Herkunft]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [B7-B8 Buchung]';

    -- ---------- naechster Export: verspaetete Zeile + Zwilling ----------
    -- Simuliert den naechsten Export: der vorige Abgleich endete heute-3 (Zeitraum heute-19..heute-3). Die Rest-Buchung
    -- von gestern liegt dadurch nach dem Schnitt -> drift/lump sind hier Artefakte und werden nicht geprueft (wie im TR-Test).
    UPDATE finance.bank_statements SET period_end = T - 3 WHERE id = (v_app->>'statement_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 3 WHERE id = v_n26;
    -- Stand heute-3 = 2870; neu: spaete Karte -5 (heute-7) + zweite identische Bäckerei-Zahlung -30 (heute-10) = -35
    -- -> Stand gestern 2835, App heute 2825
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('closing_balance', '2825',
                 'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_rows || jsonb_build_array(
                     pg_temp.n26_row(T - 10, 'Baeckerei Test', '', 'Presentment', '', '-30.00'),
                     pg_temp.n26_row(T - 7, 'Spaet Test', '', 'Presentment', '', '-5')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'late_count')::int <> 2
       OR (v_res->>'unmatched_out')::numeric <> -35 OR jsonb_array_length(v_res->'matched') <> 0
       OR jsonb_array_length(v_res->'already_booked') <> 0 THEN
        RAISE EXCEPTION 'FAIL [B9 nur Zwilling + spaete Zeile, kein zweiter Transfer]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [B9 naechster Export]';
END $$;
ROLLBACK;
