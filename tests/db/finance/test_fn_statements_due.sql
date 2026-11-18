-- ============================================================
-- test_fn_statements_due -- die eine Regel "welcher Kontoauszug ist faellig" (Erinnerung und Bot lesen dieselbe fn)
--   finance.fn_statements_due(p_today): Stichtag = letzter Tag des Vormonats von p_today. Faellig ist ein Konto mit
--   Kontoauszug (Kontonummer, Bank oder schon ein Auszug), dessen bestaetigter Stand den Stichtag nicht erreicht.
--   Ein Datei-Export (Zeitraum waehlt der Nutzer) erwartet jeden Monat einen neuen; nur ein gedruckter Auszug einer
--   Bank ohne Export-Profil gibt mit seiner Laenge den Takt vor (Quartalsauszug fragt jedes Quartal).
--   Werte erfunden; Zeitraeume in der Zukunft (2030/2031), damit Fixture-Konten nicht stoeren (Filter __t_sd_).
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
-- Auszug als Fixture-Zeile (die fn liest nur Zeitraum, Herkunft und den bestaetigten Tag des Kontos)
CREATE FUNCTION pg_temp.sd_stmt(p_acc int, p_start date, p_end date, p_source text)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                         line_count, matched_count, unmatched_out, unmatched_in, balance_source)
    VALUES (p_acc, p_start, p_end, 0, 0, 'EUR', 0, 0, 0, 0, p_source);
    UPDATE finance.accounts SET last_reconciled_at = GREATEST(COALESCE(last_reconciled_at, p_end), p_end),
                                last_reconciled_balance = 0 WHERE id = p_acc;
$$;
CREATE FUNCTION pg_temp.sd_due(p_today date)
RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE(string_agg(e->>'name', ',' ORDER BY e->>'name'), '')
    FROM jsonb_array_elements(finance.fn_statements_due(p_today)->'accounts') e
    WHERE e->>'name' LIKE '\_\_t\_sd\_%';
$$;
DO $$
DECLARE
    v_short INT; v_full INT; v_sep INT; v_qtr INT; v_man INT; v_exp INT; v_year INT; v_r JSONB;
BEGIN
    -- kurzer Datei-Export (N26, App-Stand): nur bis 19.10. bestaetigt -> Oktober fehlt
    v_short := pg_temp.sd_acc('__t_sd_short__', 'N26');
    PERFORM pg_temp.sd_stmt(v_short, DATE '2030-10-01', DATE '2030-10-19', 'owner');
    -- Datei-Export bis zum Stichtag -> nicht faellig
    v_exp := pg_temp.sd_acc('__t_sd_export_full__', 'N26');
    PERFORM pg_temp.sd_stmt(v_exp, DATE '2030-10-01', DATE '2030-10-31', 'owner');
    -- gedruckter Monatsauszug Oktober -> nicht faellig; nur September -> faellig
    v_full := pg_temp.sd_acc('__t_sd_pdf_oct__', 'Lindenbank', 'DE02100100100006820101');
    PERFORM pg_temp.sd_stmt(v_full, DATE '2030-10-01', DATE '2030-10-31', 'printed');
    v_sep := pg_temp.sd_acc('__t_sd_pdf_sep__', 'Lindenbank', 'DE89370400440532013000');
    PERFORM pg_temp.sd_stmt(v_sep, DATE '2030-09-01', DATE '2030-09-30', 'printed');
    -- gedruckter Quartalsauszug Q3 -> am 03.11. und 03.12. nicht faellig, am 03.01. faellig
    v_qtr := pg_temp.sd_acc('__t_sd_pdf_qtr__', 'Lindenbank');
    PERFORM pg_temp.sd_stmt(v_qtr, DATE '2030-07-01', DATE '2030-09-30', 'printed');
    -- langer gedruckter Datei-Export (Bondora, druckt seinen Stand; Zeitraum waehlt der Nutzer) -> Takt 1 Monat
    v_year := pg_temp.sd_acc('__t_sd_bondora_year__', 'Bondora');
    PERFORM pg_temp.sd_stmt(v_year, DATE '2029-10-01', DATE '2030-09-30', 'printed');
    -- ohne Auszug, Stand per Chat bis zum Stichtag bestaetigt -> nicht faellig
    v_man := pg_temp.sd_acc('__t_sd_manual__', 'Lindenbank');
    UPDATE finance.accounts SET last_reconciled_at = DATE '2030-10-31', last_reconciled_balance = 0 WHERE id = v_man;
    -- nie bestaetigt (Bank angegeben) -> faellig, never
    PERFORM pg_temp.sd_acc('__t_sd_never__', 'Lindenbank');
    -- kein Kandidat: Bargeld ohne Bank/Nummer/Auszug; geschlossenes Konto
    PERFORM pg_temp.sd_acc('__t_sd_cash__', NULL);
    PERFORM pg_temp.sd_acc('__t_sd_closed__', 'Lindenbank', NULL, 'closed');

    v_r := finance.fn_statements_due(DATE '2030-11-03');
    IF (v_r->>'cut_date')::date IS DISTINCT FROM DATE '2030-10-31' THEN
        RAISE EXCEPTION 'FAIL [SD1 Stichtag = letzter Tag des Vormonats]: %', v_r->>'cut_date';
    END IF;
    IF pg_temp.sd_due(DATE '2030-11-03') IS DISTINCT FROM '__t_sd_bondora_year__,__t_sd_never__,__t_sd_pdf_sep__,__t_sd_short__' THEN
        RAISE EXCEPTION 'FAIL [SD2 faellig am 03.11.: kurzer Export, September-PDF, Bondora-Jahr, nie]: %', pg_temp.sd_due(DATE '2030-11-03');
    END IF;
    IF (SELECT (e->>'covered_until')::date FROM jsonb_array_elements(v_r->'accounts') e WHERE e->>'name' = '__t_sd_short__')
       IS DISTINCT FROM DATE '2030-10-19'
       OR (SELECT (e->>'file_export')::boolean FROM jsonb_array_elements(v_r->'accounts') e WHERE e->>'name' = '__t_sd_short__')
       IS DISTINCT FROM true
       OR (SELECT (e->>'never')::boolean FROM jsonb_array_elements(v_r->'accounts') e WHERE e->>'name' = '__t_sd_never__')
       IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [SD3 covered_until/file_export/never]: %', v_r->'accounts';
    END IF;
    -- 17. desselben Monats: derselbe Stichtag, dieselbe Menge
    IF pg_temp.sd_due(DATE '2030-11-17') IS DISTINCT FROM pg_temp.sd_due(DATE '2030-11-03') THEN
        RAISE EXCEPTION 'FAIL [SD4 17. = 3.]: %', pg_temp.sd_due(DATE '2030-11-17');
    END IF;
    -- Quartal: 03.12. weiter nicht faellig, 03.01. faellig
    IF pg_temp.sd_due(DATE '2030-12-03') LIKE '%__t_sd_pdf_qtr__%' THEN
        RAISE EXCEPTION 'FAIL [SD5 Quartalsauszug am 03.12. nicht faellig]: %', pg_temp.sd_due(DATE '2030-12-03');
    END IF;
    IF pg_temp.sd_due(DATE '2031-01-03') NOT LIKE '%__t_sd_pdf_qtr__%' THEN
        RAISE EXCEPTION 'FAIL [SD6 Quartalsauszug am 03.01. faellig]: %', pg_temp.sd_due(DATE '2031-01-03');
    END IF;
    -- Datei-Export bis 31.10.: am 03.12. faellig (November fehlt)
    IF pg_temp.sd_due(DATE '2030-12-03') NOT LIKE '%__t_sd_export_full__%' THEN
        RAISE EXCEPTION 'FAIL [SD7 Export bis Oktober am 03.12. faellig]: %', pg_temp.sd_due(DATE '2030-12-03');
    END IF;
    RAISE NOTICE 'PASS [SD1-SD7 eine Regel Auszug faellig]';
END $$;
ROLLBACK;
