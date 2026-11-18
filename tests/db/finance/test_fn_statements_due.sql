-- ============================================================
-- test_fn_statements_due -- die eine Regel "welcher Kontoauszug ist faellig" (Erinnerung und Bot lesen dieselbe fn)
--   finance.fn_statements_due(p_today): Stichtag = letzter Tag des Vormonats von p_today. Kandidaten wie die
--   Erinnerung: aktive cash-Konten mit Kontonummer, Bank oder schon einem Auszug.
--   Gedruckter Auszug eines Kontos ohne Export-Profil: die Bank gibt den Takt vor -> faellig, wenn letztes Auszugs-Ende
--   + Takt (gerundete Laenge in Monaten, mind. 1) <= Stichtag und der Stand nicht schon per Chat bis zum Stichtag
--   bestaetigt ist. Sonst (Datei-Export, Konto mit Export-Profil, kein Auszug): faellig, wenn der bestaetigte Tag
--   (fn_account_confirmed_until) vor dem Stichtag liegt. Ohne jedes Datum: never.
--   Werte erfunden; Zeitraeume 2030/2031, damit Fixture-Konten nicht stoeren (Filter __t_sd_).
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.sd_acc(p_name text, p_bank text, p_number text DEFAULT NULL, p_status text DEFAULT 'active')
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_id INT;
BEGIN
    v_id := (finance.fn_create_account(jsonb_build_object('name', p_name, 'account_type', 'cash', 'currency', 'EUR',
                 'bank', p_bank, 'account_number', p_number))->>'account_id')::int;
    IF v_id IS NULL THEN RAISE EXCEPTION 'SETUP %', p_name; END IF;
    IF p_status <> 'active' THEN UPDATE finance.accounts SET status = p_status::finance.account_status WHERE id = v_id; END IF;
    RETURN v_id;
END $$;
-- Auszug als Fixture-Zeile (die fn liest nur Zeitraum, Herkunft und die bestaetigten Tage des Kontos)
CREATE FUNCTION pg_temp.sd_stmt(p_acc int, p_start date, p_end date, p_source text)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                         line_count, matched_count, unmatched_out, unmatched_in, balance_source)
    VALUES (p_acc, p_start, p_end, 0, 0, 'EUR', 0, 0, 0, 0, p_source);
    UPDATE finance.accounts SET last_reconciled_at = GREATEST(COALESCE(last_reconciled_at, p_end), p_end),
                                last_reconciled_balance = 0 WHERE id = p_acc;
$$;
CREATE FUNCTION pg_temp.sd_is_due(p_today date, p_name text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_statements_due(p_today)->'accounts') e
                   WHERE e->>'name' = p_name);
END $$;
CREATE FUNCTION pg_temp.sd_entry(p_today date, p_name text)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    RETURN (SELECT e FROM jsonb_array_elements(finance.fn_statements_due(p_today)->'accounts') e WHERE e->>'name' = p_name);
END $$;
CREATE FUNCTION pg_temp.sd_expect(p_today date, p_name text, p_due boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF pg_temp.sd_is_due(p_today, p_name) IS DISTINCT FROM p_due THEN
        RAISE EXCEPTION 'FAIL [%]: % am % faellig=% erwartet', p_label, p_name, p_today, p_due;
    END IF;
END $$;
DO $$
DECLARE
    v_id INT; v_r JSONB;
    N3 DATE := DATE '2030-11-03';
BEGIN
    -- Datei-Export (N26, App-Stand): nur bis 19.10. bestaetigt -> Oktober fehlt
    v_id := pg_temp.sd_acc('__t_sd_short__', 'N26');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-10-01', DATE '2030-10-19', 'owner');
    -- Datei-Export bis zum Stichtag
    v_id := pg_temp.sd_acc('__t_sd_export_full__', 'N26');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-10-01', DATE '2030-10-31', 'owner');
    -- gedruckte Monatsauszuege einer Bank ohne Export-Profil
    v_id := pg_temp.sd_acc('__t_sd_pdf_oct__', 'Lindenbank', 'DE02100100100006820101');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-10-01', DATE '2030-10-31', 'printed');
    v_id := pg_temp.sd_acc('__t_sd_pdf_sep__', 'Lindenbank', 'DE89370400440532013000');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-09-01', DATE '2030-09-30', 'printed');
    -- eigener Zyklus der Bank 15.-14.
    v_id := pg_temp.sd_acc('__t_sd_pdf_cycle__', 'Lindenbank');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-09-15', DATE '2030-10-14', 'printed');
    -- Quartalsauszuege: Q3 (bis 30.09.) und Q2 (bis 30.06., Monatsende-Kappung)
    v_id := pg_temp.sd_acc('__t_sd_pdf_q3__', 'Lindenbank');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-07-01', DATE '2030-09-30', 'printed');
    v_id := pg_temp.sd_acc('__t_sd_pdf_q2__', 'Lindenbank');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-04-01', DATE '2030-06-30', 'printed');
    -- Konto mit Export-Profil schickt ein Quartals-PDF -> Takt 1 Monat
    v_id := pg_temp.sd_acc('__t_sd_profile_qtr__', 'N26');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-07-01', DATE '2030-09-30', 'printed');
    -- September-PDF, danach per Chat bis 31.10. bestaetigt -> nicht faellig
    v_id := pg_temp.sd_acc('__t_sd_pdf_then_chat__', 'Lindenbank');
    PERFORM pg_temp.sd_stmt(v_id, DATE '2030-09-01', DATE '2030-09-30', 'printed');
    UPDATE finance.accounts SET last_reconciled_at = DATE '2030-10-31' WHERE id = v_id;
    -- ohne Auszug, per Chat bis zum Stichtag bestaetigt
    v_id := pg_temp.sd_acc('__t_sd_manual__', 'Lindenbank');
    UPDATE finance.accounts SET last_reconciled_at = DATE '2030-10-31', last_reconciled_balance = 0 WHERE id = v_id;
    -- ohne Auszug, Startdatum 15.10. -> bestaetigt bis 15.10., faellig, nicht never
    v_id := pg_temp.sd_acc('__t_sd_opened__', 'Lindenbank');
    UPDATE finance.accounts SET opening_balance_date = DATE '2030-10-15', last_reconciled_at = NULL WHERE id = v_id;
    -- nie bestaetigt (Bank angegeben, kein Datum) -> faellig, never
    v_id := pg_temp.sd_acc('__t_sd_never__', 'Lindenbank');
    UPDATE finance.accounts SET opening_balance_date = NULL, last_reconciled_at = NULL WHERE id = v_id;
    -- kein Kandidat: Bargeld ohne Bank/Nummer/Auszug; geschlossenes Konto
    PERFORM pg_temp.sd_acc('__t_sd_cash__', NULL);
    PERFORM pg_temp.sd_acc('__t_sd_closed__', 'Lindenbank', NULL, 'closed');

    v_r := finance.fn_statements_due(N3);
    IF (v_r->>'cut_date')::date IS DISTINCT FROM DATE '2030-10-31' THEN
        RAISE EXCEPTION 'FAIL [SD1 Stichtag = letzter Tag des Vormonats]: %', v_r->>'cut_date';
    END IF;
    -- SD2 am 03.11.
    PERFORM pg_temp.sd_expect(N3, '__t_sd_short__', true, 'SD2 kurzer Export');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_export_full__', false, 'SD2 Export bis Stichtag');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_pdf_oct__', false, 'SD2 PDF Oktober');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_pdf_sep__', true, 'SD2 PDF nur September');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_pdf_cycle__', false, 'SD2 Zyklus 15.-14., naechster erst am 14.11.');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_pdf_q3__', false, 'SD2 Quartal Q3');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_profile_qtr__', true, 'SD2 Profil-Konto mit Quartals-PDF');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_pdf_then_chat__', false, 'SD2 PDF dann Chat-Bestaetigung');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_manual__', false, 'SD2 Chat bis Stichtag');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_opened__', true, 'SD2 Startdatum im Oktober');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_never__', true, 'SD2 nie bestaetigt');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_cash__', false, 'SD2 Bargeld kein Kandidat');
    PERFORM pg_temp.sd_expect(N3, '__t_sd_closed__', false, 'SD2 geschlossen kein Kandidat');
    -- SD3 Felder je Eintrag
    IF (pg_temp.sd_entry(N3, '__t_sd_short__')->>'covered_until')::date IS DISTINCT FROM DATE '2030-10-19'
       OR (pg_temp.sd_entry(N3, '__t_sd_short__')->>'file_export')::boolean IS DISTINCT FROM true
       OR (pg_temp.sd_entry(N3, '__t_sd_opened__')->>'covered_until')::date IS DISTINCT FROM DATE '2030-10-15'
       OR (pg_temp.sd_entry(N3, '__t_sd_opened__')->>'never')::boolean IS DISTINCT FROM false
       OR (pg_temp.sd_entry(N3, '__t_sd_never__')->>'never')::boolean IS DISTINCT FROM true
       OR pg_temp.sd_entry(N3, '__t_sd_never__')->>'covered_until' IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [SD3 covered_until/file_export/never]: % / % / %', pg_temp.sd_entry(N3, '__t_sd_short__'),
            pg_temp.sd_entry(N3, '__t_sd_opened__'), pg_temp.sd_entry(N3, '__t_sd_never__');
    END IF;
    -- SD4 der 17. hat denselben Stichtag
    PERFORM pg_temp.sd_expect(DATE '2030-11-17', '__t_sd_short__', true, 'SD4 17. = 3.');
    PERFORM pg_temp.sd_expect(DATE '2030-11-17', '__t_sd_pdf_cycle__', false, 'SD4 17. = 3.');
    -- SD5 Folgemonate
    PERFORM pg_temp.sd_expect(DATE '2030-12-03', '__t_sd_export_full__', true, 'SD5 Export bis Oktober am 03.12.');
    PERFORM pg_temp.sd_expect(DATE '2030-12-03', '__t_sd_pdf_cycle__', true, 'SD5 Zyklus am 03.12.');
    PERFORM pg_temp.sd_expect(DATE '2030-12-03', '__t_sd_pdf_q3__', false, 'SD5 Quartal Q3 am 03.12.');
    PERFORM pg_temp.sd_expect(DATE '2031-01-03', '__t_sd_pdf_q3__', true, 'SD5 Quartal Q3 am 03.01.');
    PERFORM pg_temp.sd_expect(DATE '2030-09-03', '__t_sd_pdf_q2__', false, 'SD5 Quartal Q2 am 03.09.');
    PERFORM pg_temp.sd_expect(DATE '2030-10-03', '__t_sd_pdf_q2__', true, 'SD5 Quartal Q2 am 03.10.');
    -- SD6 Reihenfolge: never zuerst, dann nach covered_until, dann Name (Q2 ist am 03.11. faellig: Q3 fehlt)
    IF (SELECT string_agg(e->>'name', ',' ORDER BY o) FROM jsonb_array_elements(v_r->'accounts') WITH ORDINALITY x(e, o)
        WHERE e->>'name' LIKE '\_\_t\_sd\_%')
       IS DISTINCT FROM '__t_sd_never__,__t_sd_pdf_q2__,__t_sd_pdf_sep__,__t_sd_profile_qtr__,__t_sd_opened__,__t_sd_short__' THEN
        RAISE EXCEPTION 'FAIL [SD6 Reihenfolge]: %', v_r->'accounts';
    END IF;
    RAISE NOTICE 'PASS [SD1-SD6 eine Regel Auszug faellig]';
END $$;
ROLLBACK;
