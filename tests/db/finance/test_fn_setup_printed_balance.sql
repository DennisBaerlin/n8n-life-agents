-- ============================================================
-- test_fn_setup_printed_balance -- Datei mit gedrucktem Stand (Profil-generisch, Bondora-Form): Anlage vom Dateianfang, Einlesen,
--   Umstellen eines schon mit spaeterem Stand angelegten Kontos. Werte erfunden.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.bd(p_d date, p_typ text, p_in text, p_out text, p_bal text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(to_char(p_d, 'FMMM/FMDD/YYYY'), p_typ, p_in, p_out, p_bal);
$$;
DO $$
DECLARE
    ps     DATE := date_trunc('month', CURRENT_DATE - 45)::date;
    pe     DATE := (date_trunc('month', CURRENT_DATE - 45) + interval '1 month - 1 day')::date;
    v_tbl  JSONB;
    v_norm JSONB;
    v_r    JSONB;
    v_acct INT;
    v_p    JSONB;
BEGIN
    v_tbl := jsonb_build_object('rows', jsonb_build_array(
        jsonb_build_array('Test Person', '', '', 'Summary', ''),
        jsonb_build_array(to_char(ps, 'FMMM/FMDD/YYYY') || '-' || to_char(pe, 'FMMM/FMDD/YYYY'), '', '', 'Opening', '100'),
        jsonb_build_array('', '', '', 'Payments in', '5'),
        jsonb_build_array('', '', '', 'Payments out', '0'),
        jsonb_build_array('', '', '', 'Closing', '105'),
        jsonb_build_array(), jsonb_build_array('All Goals'),
        jsonb_build_array('Date', 'Payment type', 'In', 'Out', 'Balance'),
        pg_temp.bd(ps, 'Go & Grow returns', '2', '', '102'),
        pg_temp.bd(ps + 3, 'Go & Grow returns', '3', '', '105')));
    v_norm := finance.fn_bank_export_normalize(v_tbl);
    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [S0 Form]: %', v_norm; END IF;

    -- Profilfelder gelten fuer alle Profile
    IF (SELECT count(*) FROM jsonb_array_elements(finance.fn_bank_export_profiles()) p
        WHERE p->>'interest_source' IN ('web','export','none') AND p ? 'is_broker' AND p ? 'default_account_type') <> jsonb_array_length(finance.fn_bank_export_profiles())
       THEN RAISE EXCEPTION 'FAIL [P1 Profilfelder]'; END IF;

    -- zweite Datei im selben Chat bei offener Einrichtung (Karte abgelehnt, nichts bestaetigt): derselbe Lauf mit der
    -- neuen Datei, Karte aus deren Werten; die DB entscheidet das, nicht das Modell
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', 'pb0', 'file_id', 'f0a', 'table', v_tbl));
    IF v_r->>'phase' <> 'cash_account' THEN RAISE EXCEPTION 'FAIL [D1 erste Datei]: %', v_r; END IF;
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', 'pb0', 'file_id', 'f0b', 'table',
        jsonb_build_object('rows', (v_tbl->'rows') || jsonb_build_array(jsonb_build_array()))));
    IF (v_r->>'setup')::boolean IS DISTINCT FROM true OR v_r->>'phase' <> 'cash_account'
       OR (v_r->'card'->'params'->>'opening_balance')::numeric <> 100 THEN RAISE EXCEPTION 'FAIL [D2 neue Datei]: %', v_r; END IF;
    IF (SELECT count(*) FROM finance.setup_session WHERE chat_id = 'pb0') <> 1
       OR (SELECT file_id FROM finance.setup_session WHERE chat_id = 'pb0') <> 'f0b' THEN RAISE EXCEPTION 'FAIL [D3 ein Lauf, neue file_id]'; END IF;
    DELETE FROM finance.setup_session WHERE chat_id = 'pb0';

    -- ohne Konto: Anker aus der Datei, keine Frage nach dem Stand, keine Websuche
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', 'pb1', 'file_id', 'f1', 'table', v_tbl));
    IF v_r->>'phase' <> 'cash_account' OR v_r ? 'ask' OR v_r->>'interest_source' <> 'export'
       OR (v_r->'card'->'params'->>'opening_balance')::numeric <> 100 OR (v_r->'card'->'params'->>'opening_balance_date')::date <> ps - 1
       OR v_r->'card'->'params'->>'account_type' <> 'p2p' THEN RAISE EXCEPTION 'FAIL [A1 Anker]: %', v_r; END IF;
    v_p := v_r->'card'->'params';
    v_acct := (finance.fn_create_account(v_p)->>'account_id')::int;

    -- danach: Schritt statement, begin schliesst den Lauf, die Datei laeuft als Monats-Check
    v_r := finance.fn_setup_advance(jsonb_build_object('chat_id', 'pb1', 'table', v_tbl));
    IF v_r->>'phase' <> 'statement' THEN RAISE EXCEPTION 'FAIL [A2 statement]: %', v_r; END IF;
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', 'pb1', 'file_id', 'f1', 'table', v_tbl));
    IF (v_r->>'setup')::boolean THEN RAISE EXCEPTION 'FAIL [A3 begin]: %', v_r; END IF;
    IF EXISTS (SELECT 1 FROM finance.setup_session WHERE chat_id = 'pb1') THEN RAISE EXCEPTION 'FAIL [A4 geschlossen]'; END IF;
    v_r := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'table', v_tbl));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'lump')::numeric <> 0 OR (v_r->>'interest_correction')::numeric <> 5
       THEN RAISE EXCEPTION 'FAIL [A5 Einlesen]: %', v_r; END IF;
    UPDATE finance.accounts SET status = 'closed', name = '__t_pb_alt__' WHERE id = v_acct;

    -- Konto zu spaet angelegt: Umstellung wird angeboten
    v_acct := (finance.fn_create_account(jsonb_build_object('name','__t_pb__','account_type','p2p','bank','Bondora','currency','EUR','opening_balance',105))->>'account_id')::int;
    v_r := finance.fn_setup_begin(jsonb_build_object('chat_id', 'pb2', 'file_id', 'f2', 'table', v_tbl));
    IF v_r->>'phase' <> 'reanchor' THEN RAISE EXCEPTION 'FAIL [B1 reanchor]: %', v_r; END IF;
    v_r := finance.fn_setup_reanchor(jsonb_build_object('chat_id', 'pb2', 'table', v_tbl));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'balance')::numeric <> 100 OR (v_r->>'opening_balance_date')::date <> ps - 1
       THEN RAISE EXCEPTION 'FAIL [B2 umgestellt]: %', v_r; END IF;
    IF (finance.fn_setup_next(jsonb_build_object('chat_id', 'pb2', 'table', v_tbl))->>'phase') <> 'statement' THEN RAISE EXCEPTION 'FAIL [B3 danach]'; END IF;

    -- schon gebucht oder Stichtag vor Datei-Ende -> keine Umstellung
    UPDATE finance.accounts SET opening_balance_date = core.fn_today() WHERE id = v_acct;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES (v_acct, 1, core.fn_today(), 'other', 'Sonstiges');
    IF (finance.fn_setup_reanchor_plan(v_acct, v_norm)->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [C1 berührt]'; END IF;
    DELETE FROM finance.transactions WHERE account_id = v_acct AND description = 'Sonstiges';
    UPDATE finance.accounts SET opening_balance_date = pe - 1 WHERE id = v_acct;
    IF (finance.fn_setup_reanchor_plan(v_acct, v_norm)->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [C2 frueher]'; END IF;
    UPDATE finance.accounts SET opening_balance_date = core.fn_today() WHERE id = v_acct;
    IF (finance.fn_setup_reanchor_plan(v_acct, v_norm || '{"printed_balance":false}')->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [C3 ohne Druck]'; END IF;
END $$;
ROLLBACK;
