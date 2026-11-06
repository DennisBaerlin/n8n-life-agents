-- ============================================================
-- test_bank_statement_iban_learn -- "Import zuerst": IBAN eines eigenen Kontos aus Ueberweisungen lernen
--   fn_statement_prepare (Abschnitt 3a2 IBAN-LERNEN: Regel 1 Name -> genau ein Konto, Regel 2 Dauerauftrags-Transfer,
--   Konflikte, Ausschluesse), fn_apply_bank_statement (learned_accounts -> fn_set_account), account_unknown + Inhaber.
--   Werte erfunden (IBANs mit gueltiger Pruefziffer). Haushalt: Maximilian + Erika Zweistein. Jedes Szenario laeuft in
--   einem eigenen Block, der sich am Ende per TR001 selbst zuruecksetzt (die Kandidaten-Suche sieht alle aktiven Konten).
-- ============================================================
BEGIN;
INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('__t_il_max__', 'Maximilian Zweistein', 'owner'),
    ('__t_il_erika__', 'Erika Zweistein', 'partner')
ON CONFLICT (person_id) DO UPDATE SET full_name = excluded.full_name;

-- Auszug (gedruckt, per Kontoname): Endsaldo = Anfang + Summe der Zeilen
CREATE FUNCTION pg_temp.stmt(p_acct text, p_ps date, p_pe date, p_open numeric, p_lines jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('account_name', p_acct, 'currency', 'EUR', 'period_start', p_ps, 'period_end', p_pe,
        'opening_balance', p_open,
        'closing_balance', p_open + COALESCE((SELECT sum((l->>'amount')::numeric) FROM jsonb_array_elements(p_lines) l), 0),
        'lines', p_lines);
$$;
CREATE FUNCTION pg_temp.ln(p_d date, p_amt numeric, p_cp text, p_iban text, p_extra jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('date', p_d, 'amount', p_amt, 'counterparty', p_cp, 'counterparty_iban', p_iban,
                              'purpose', 'Test') || p_extra;
$$;
-- Konto mit bestaetigtem Stand 1000 am Vortag des Zeitraums
CREATE FUNCTION pg_temp.acct(p_name text, p_owner text, p_iban text, p_ps date) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_id INT; v_r JSONB;
BEGIN
    v_r := finance.fn_create_account(jsonb_build_object('name', p_name, 'account_type', 'cash', 'currency', 'EUR',
               'owner_person_id', p_owner, 'account_number', p_iban));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP %: %', p_name, v_r; END IF;
    v_id := (v_r->>'account_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_id, 1000, p_ps - 20, 'other');
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_id, 'confirmed_balance', 1000,
                'reconciliation_date', (p_ps - 1)::text));
    RETURN v_id;
END $$;

-- ---------- S1: Regel 1 lernt, Apply speichert, Folgeauszug trifft per Stufe T, Storno laesst die IBAN stehen ----------
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_a INT; v_n INT; v_s JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    v_a := pg_temp.acct('__t_il_a__', '__t_il_max__', 'DE93500105174400000001', ps);
    v_n := pg_temp.acct('__t_il_n26__', '__t_il_max__', NULL, ps);
    v_s := pg_temp.stmt('__t_il_a__', ps, pe, 1000, jsonb_build_array(
        pg_temp.ln(ps + 3, -200, 'ZWEISTEIN, MAXIMILIAN', 'DE66 5001 0517 4400 0000 02'),
        pg_temp.ln(ps + 8, -50, 'Maximilian Zweistein', 'DE66500105174400000002'),
        pg_temp.ln(ps + 12, -30, 'REWE Markt', NULL)));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [L1 prepare]: %', v_prep; END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'matched') m
        WHERE m->>'kind' = 'transfer' AND m->>'stage' = 'L' AND (m->>'other_account_id')::int = v_n) <> 2 THEN
        RAISE EXCEPTION 'FAIL [L1a zwei Zeilen als Uebertrag an N26 (Stufe L)]: %', v_prep->'matched';
    END IF;
    IF jsonb_array_length(v_prep->'learned_accounts') <> 1
       OR (v_prep->'learned_accounts'->0->>'account_id')::int <> v_n
       OR v_prep->'learned_accounts'->0->>'account_number' <> 'DE66500105174400000002'
       OR jsonb_array_length(v_prep->'iban_ambiguous') <> 0 THEN
        RAISE EXCEPTION 'FAIL [L1b learned_accounts]: %', v_prep->'learned_accounts';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c
                   WHERE c->>'value' = 'finance.note.iban_learned_other'
                     AND c->'params'->>'iban' = 'DE66500105174400000002' AND c->'params'->>'account' = '__t_il_n26__') THEN
        RAISE EXCEPTION 'FAIL [L1c Karten-Notiz]: %', v_prep->'card_lines';
    END IF;
    IF (v_prep->>'lump')::numeric <> -30 THEN RAISE EXCEPTION 'FAIL [L1d Rest nur REWE]: %', v_prep->>'lump'; END IF;

    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [L1e apply]: %', v_app; END IF;
    IF (SELECT account_number FROM finance.accounts WHERE id = v_n) IS DISTINCT FROM 'DE66500105174400000002'
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_n) <> 1250
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_a) <> 720
       OR jsonb_array_length(v_app->'learned_accounts') <> 1
       OR (v_app->'learned_accounts'->0->>'account_id')::int <> v_n THEN
        RAISE EXCEPTION 'FAIL [L1f IBAN gespeichert, Salden A 720 / N26 1250]: % / %', v_app,
            (SELECT balance FROM finance.account_balances WHERE account_id = v_n);
    END IF;

    -- Folgemonat: dieselbe IBAN ist jetzt Kontonummer -> Stufe T, nichts mehr zu lernen
    v_prep := finance.fn_statement_prepare(pg_temp.stmt('__t_il_a__', pe + 1, pe + 28, 720, jsonb_build_array(
        pg_temp.ln(pe + 5, -10, 'Maximilian Zweistein', 'DE66500105174400000002'))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR v_prep->'matched'->0->>'stage' <> 'T'
       OR jsonb_array_length(v_prep->'learned_accounts') <> 0 THEN
        RAISE EXCEPTION 'FAIL [L1g Folgeauszug Stufe T]: %', v_prep;
    END IF;

    -- Storno des Auszugs: die gelernte IBAN bleibt (Stammdatum, Korrektur ueber remove_account_number)
    v_app := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_a));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT account_number FROM finance.accounts WHERE id = v_n) IS DISTINCT FROM 'DE66500105174400000002' THEN
        RAISE EXCEPTION 'FAIL [L1h Storno laesst IBAN stehen]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [L1 Regel 1: lernen, buchen, Stufe T, Storno]';
    RAISE EXCEPTION USING ERRCODE = 'TR001', MESSAGE = 'Szenario zuruecksetzen';
EXCEPTION WHEN SQLSTATE 'TR001' THEN NULL;   -- nur das Zuruecksetzen, FAIL-Meldungen laufen durch
END $$;

-- ---------- S2: zwei Kandidaten -> Hinweis, kein Lernen; zwei Namen -> nur Haushaltskonto; eine Person -> nur ihre
--            Konten (das Haushaltskonto ist fuer einen Einzelnamen nie Kandidat, Code-Review 2026-10-30) ----------
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_a INT; v_n INT; v_n2 INT; v_j INT; v_prep JSONB;
BEGIN
    v_a := pg_temp.acct('__t_il_a__', '__t_il_max__', 'DE93500105174400000001', ps);
    v_n := pg_temp.acct('__t_il_n26__', '__t_il_max__', NULL, ps);
    v_n2 := pg_temp.acct('__t_il_tg__', '__t_il_max__', NULL, ps);
    v_j := pg_temp.acct('__t_il_joint__', NULL, NULL, ps);
    v_prep := finance.fn_statement_prepare(pg_temp.stmt('__t_il_a__', ps, pe, 1000, jsonb_build_array(
        pg_temp.ln(ps + 3, -200, 'Maximilian Zweistein', 'DE66500105174400000002'),
        pg_temp.ln(ps + 4, -80, 'Maximilian und Erika Zweistein', 'DE39500105174400000003'))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [L2 prepare]: %', v_prep; END IF;
    IF jsonb_array_length(v_prep->'learned_accounts') <> 1 OR (v_prep->'learned_accounts'->0->>'account_id')::int <> v_j
       OR v_prep->'learned_accounts'->0->>'account_number' <> 'DE39500105174400000003' THEN
        RAISE EXCEPTION 'FAIL [L2a zwei Namen -> Haushaltskonto]: %', v_prep->'learned_accounts';
    END IF;
    IF jsonb_array_length(v_prep->'iban_ambiguous') <> 1
       OR v_prep->'iban_ambiguous'->0->>'account_number' <> 'DE66500105174400000002'
       OR (SELECT string_agg(x, ',' ORDER BY x) FROM jsonb_array_elements_text(v_prep->'iban_ambiguous'->0->'candidates') x)
          <> '__t_il_n26__,__t_il_tg__' OR (v_prep->'iban_ambiguous'->0->>'conflict')::boolean THEN
        RAISE EXCEPTION 'FAIL [L2b eine Person mit zwei Konten ohne IBAN = mehrdeutig]: %', v_prep->'iban_ambiguous';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'value' = 'finance.note.iban_learn_ambiguous'
                   AND c->'params'->>'accounts' = '__t_il_n26__, __t_il_tg__') THEN
        RAISE EXCEPTION 'FAIL [L2c Hinweis auf der Karte]: %', v_prep->'card_lines';
    END IF;
    IF (v_prep->>'lump')::numeric <> -200 THEN RAISE EXCEPTION 'FAIL [L2d mehrdeutige Zeile bleibt im Rest]: %', v_prep->>'lump'; END IF;
    RAISE NOTICE 'PASS [L2 mehrdeutig + gemeinsam]';
    RAISE EXCEPTION USING ERRCODE = 'TR001', MESSAGE = 'Szenario zuruecksetzen';
EXCEPTION WHEN SQLSTATE 'TR001' THEN NULL;   -- nur das Zuruecksetzen, FAIL-Meldungen laufen durch
END $$;

-- ---------- S3: nichts zu lernen (fremder Name, Person ohne Konto, geschlossenes Konto, eigene IBAN, maskiert,
--            gemischte Namen, Zeilenarten) ----------
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_a INT; v_n INT; v_c INT; v_j INT; r_t INT; v_prep JSONB;
BEGIN
    v_a := pg_temp.acct('__t_il_a__', '__t_il_max__', 'DE93500105174400000001', ps);
    v_n := pg_temp.acct('__t_il_n26__', '__t_il_max__', NULL, ps);
    -- Haushaltskonto ohne IBAN: fuer Erikas Einzelnamen nie Kandidat (ihr eigenes Konto fehlt im System)
    v_j := pg_temp.acct('__t_il_joint__', NULL, NULL, ps);
    v_c := pg_temp.acct('__t_il_closed__', '__t_il_max__', 'DE12500105174400000004', ps);
    UPDATE finance.accounts SET status = 'closed' WHERE id = v_c;
    -- Dauerauftrag an einen Dritten (kein Transfer), dessen Zeile die IBAN als Schluessel lernt -> diese IBAN ist nie
    -- ein eigenes Konto, auch nicht fuer eine weitere Zeile mit passendem Namen
    r_t := finance.fn_add_recurring_payment(v_a, -30, 'Taschengeld', 1::smallint, 'month'::finance.schedule_unit, 20::smallint,
               (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
    v_prep := finance.fn_statement_prepare(pg_temp.stmt('__t_il_a__', ps, pe, 1000, jsonb_build_array(
        pg_temp.ln(ps + 1, -10, 'Gustav Fremdling', 'DE66500105174400000002'),
        pg_temp.ln(ps + 2, -11, 'Erika Zweistein', 'DE39500105174400000003'),
        pg_temp.ln(ps + 3, -12, 'Maximilian Zweistein', 'DE12500105174400000004'),
        pg_temp.ln(ps + 4, -13, 'Maximilian Zweistein', 'DE93500105174400000001'),
        pg_temp.ln(ps + 5, -14, 'Maximilian Zweistein', 'DE89XXXXXXXXXXXXXX3000'),
        pg_temp.ln(ps + 6, -15, 'Maximilian Zweistein', 'DE82500105174400000005'),
        pg_temp.ln(ps + 7, -16, 'Zweistein Handels GmbH', 'DE82500105174400000005'),
        pg_temp.ln(ps + 8, -17, 'Maximilian Zweistein', 'DE55500105174400000006', '{"kind":"fee"}'),
        pg_temp.ln(ps + 9, 18, 'Maximilian Zweistein', 'DE28500105174400000007', '{"kind":"cash","sub_kind":"deposit"}'),
        pg_temp.ln(ps + 10, 19, 'Maximilian Zweistein', 'DE98500105174400000008', '{"kind":"interest_line"}'),
        pg_temp.ln(ps + 19, -30, 'Maximilian Zweistein', 'DE71500105174400000009'),
        pg_temp.ln(ps + 22, -5, 'Maximilian Zweistein', 'DE71500105174400000009'))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [L3 prepare]: %', v_prep; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'learn') k WHERE k->>'key_value' = 'DE71500105174400000009') THEN
        RAISE EXCEPTION 'FAIL [L3 Kontrolle: Taschengeld lernt die IBAN als Schluessel]: %', v_prep->'learn';
    END IF;
    IF jsonb_array_length(v_prep->'learned_accounts') <> 0 OR jsonb_array_length(v_prep->'iban_ambiguous') <> 0
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'matched') m WHERE m->>'stage' = 'L') THEN
        RAISE EXCEPTION 'FAIL [L3 nichts lernen]: learned % amb % matched %', v_prep->'learned_accounts',
            v_prep->'iban_ambiguous', v_prep->'matched';
    END IF;
    RAISE NOTICE 'PASS [L3 Ausschluesse]';
    RAISE EXCEPTION USING ERRCODE = 'TR001', MESSAGE = 'Szenario zuruecksetzen';
EXCEPTION WHEN SQLSTATE 'TR001' THEN NULL;   -- nur das Zuruecksetzen, FAIL-Meldungen laufen durch
END $$;

-- ---------- S4: Regel 2 (Dauerauftrags-Transfer an Konto ohne IBAN) + weitere Zeile derselben IBAN ----------
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_a INT; v_n INT; v_n2 INT; r_n INT; r_n2 INT; v_prep JSONB;
BEGIN
    v_a := pg_temp.acct('__t_il_a__', '__t_il_max__', 'DE93500105174400000001', ps);
    v_n := pg_temp.acct('__t_il_n26__', '__t_il_max__', NULL, ps);
    v_n2 := pg_temp.acct('__t_il_tg__', '__t_il_max__', NULL, ps);
    r_n := finance.fn_add_recurring_payment(v_a, -100, 'Sparrate N26', 1::smallint, 'month'::finance.schedule_unit, 10::smallint,
               (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_n WHERE id = r_n;
    -- zweiter Dauerauftrag an ein Konto ohne IBAN, aber Gegenpart-Name fremd -> nie lernen
    r_n2 := finance.fn_add_recurring_payment(v_a, -40, 'Sparrate TG', 1::smallint, 'month'::finance.schedule_unit, 15::smallint,
               (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_n2 WHERE id = r_n2;
    v_prep := finance.fn_statement_prepare(pg_temp.stmt('__t_il_a__', ps, pe, 1000, jsonb_build_array(
        pg_temp.ln(ps + 9, -100, 'ZWEISTEIN MAXIMILIAN', 'DE66500105174400000002'),
        pg_temp.ln(ps + 14, -40, 'Fremd Bank AG', 'DE39500105174400000003'),
        pg_temp.ln(ps + 20, -25, 'Maximilian Zweistein', 'DE66500105174400000002'))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [L4 prepare]: %', v_prep; END IF;
    IF jsonb_array_length(v_prep->'learned_accounts') <> 1 OR (v_prep->'learned_accounts'->0->>'account_id')::int <> v_n
       OR v_prep->'learned_accounts'->0->>'account_number' <> 'DE66500105174400000002' THEN
        RAISE EXCEPTION 'FAIL [L4a Regel 2 lernt N26]: %', v_prep->'learned_accounts';
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'matched') m WHERE m->>'kind' = 'recurring') <> 2
       OR (SELECT count(*) FROM jsonb_array_elements(v_prep->'matched') m
           WHERE m->>'stage' = 'L' AND (m->>'other_account_id')::int = v_n AND (m->>'amount')::numeric = -25) <> 1 THEN
        RAISE EXCEPTION 'FAIL [L4b Dauerauftraege bleiben recurring, -25 als Uebertrag an N26]: %', v_prep->'matched';
    END IF;
    IF jsonb_array_length(v_prep->'iban_ambiguous') <> 0 THEN
        RAISE EXCEPTION 'FAIL [L4c kein Hinweis]: %', v_prep->'iban_ambiguous';
    END IF;
    RAISE NOTICE 'PASS [L4 Regel 2]';
    RAISE EXCEPTION USING ERRCODE = 'TR001', MESSAGE = 'Szenario zuruecksetzen';
EXCEPTION WHEN SQLSTATE 'TR001' THEN NULL;   -- nur das Zuruecksetzen, FAIL-Meldungen laufen durch
END $$;

-- ---------- S5: Konflikte (zwei IBANs -> ein Konto; Regel 2 gegen Regel 1) -> nichts lernen, kein 23505 ----------
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_a INT; v_n INT; r_n INT; v_s JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    v_a := pg_temp.acct('__t_il_a__', '__t_il_max__', 'DE93500105174400000001', ps);
    v_n := pg_temp.acct('__t_il_n26__', '__t_il_max__', NULL, ps);
    -- (a) zwei verschiedene IBANs desselben Namens -> beide nur auf N26
    v_prep := finance.fn_statement_prepare(pg_temp.stmt('__t_il_a__', ps, pe, 1000, jsonb_build_array(
        pg_temp.ln(ps + 3, -200, 'Maximilian Zweistein', 'DE66500105174400000002'),
        pg_temp.ln(ps + 4, -20, 'Maximilian Zweistein', 'DE39500105174400000003'))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'learned_accounts') <> 0
       OR jsonb_array_length(v_prep->'iban_ambiguous') <> 2
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'iban_ambiguous') x WHERE NOT (x->>'conflict')::boolean) THEN
        RAISE EXCEPTION 'FAIL [L5a zwei IBANs -> ein Konto]: %', v_prep;
    END IF;
    -- Konflikt-Hinweis ist ein eigener Text (nicht "passt zu mehreren Konten")
    IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'card_lines') c
        WHERE c->>'value' = 'finance.note.iban_learn_conflict' AND c->'params'->>'account' = '__t_il_n26__') <> 2
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'value' = 'finance.note.iban_learn_ambiguous') THEN
        RAISE EXCEPTION 'FAIL [L5a Konflikt-Hinweis]: %', v_prep->'card_lines';
    END IF;
    -- (b) Regel 2 (Dauerauftrag an N26, IBAN 2) gegen Regel 1 (IBAN 3 -> N26)
    r_n := finance.fn_add_recurring_payment(v_a, -100, 'Sparrate N26', 1::smallint, 'month'::finance.schedule_unit, 10::smallint,
               (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_n WHERE id = r_n;
    v_s := pg_temp.stmt('__t_il_a__', ps, pe, 1000, jsonb_build_array(
        pg_temp.ln(ps + 9, -100, 'Maximilian Zweistein', 'DE66500105174400000002'),
        pg_temp.ln(ps + 12, -15, 'Maximilian Zweistein', 'DE39500105174400000003')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'learned_accounts') <> 0
       OR jsonb_array_length(v_prep->'iban_ambiguous') <> 2
       OR (SELECT count(*) FROM jsonb_array_elements(v_prep->'matched') m WHERE m->>'kind' = 'recurring') <> 1 THEN
        RAISE EXCEPTION 'FAIL [L5b Regel 2 gegen Regel 1]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR (SELECT account_number FROM finance.accounts WHERE id = v_n) IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [L5c apply ohne Lernen]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [L5 Konflikte]';
    RAISE EXCEPTION USING ERRCODE = 'TR001', MESSAGE = 'Szenario zuruecksetzen';
EXCEPTION WHEN SQLSTATE 'TR001' THEN NULL;   -- nur das Zuruecksetzen, FAIL-Meldungen laufen durch
END $$;

-- ---------- S6: Gegenkonto schon abgeglichen -> blocked, aber gelernt; Fingerprint deckt das Lernen ab ----------
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_a INT; v_n INT; v_s JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    v_a := pg_temp.acct('__t_il_a__', '__t_il_max__', 'DE93500105174400000001', ps);
    v_n := pg_temp.acct('__t_il_n26__', '__t_il_max__', NULL, ps);
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_n, 'confirmed_balance', 1000,
                'reconciliation_date', pe::text));
    v_s := pg_temp.stmt('__t_il_a__', ps, pe, 1000, jsonb_build_array(
        pg_temp.ln(ps + 3, -200, 'Maximilian Zweistein', 'DE66500105174400000002')));
    v_prep := finance.fn_statement_prepare(v_s);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT count(*) FROM jsonb_array_elements(v_prep->'blocked') b WHERE b->>'reason' = 'partner_reconciled') <> 1
       OR jsonb_array_length(v_prep->'learned_accounts') <> 1 THEN
        RAISE EXCEPTION 'FAIL [L6a blocked, aber gelernt]: %', v_prep;
    END IF;
    -- zwischen Karte und Tipp wird die IBAN anders gesetzt -> stale_preview, nichts gebucht
    UPDATE finance.accounts SET account_number = 'DE82500105174400000005' WHERE id = v_n;
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF v_app->>'code' IS DISTINCT FROM 'stale_preview' THEN RAISE EXCEPTION 'FAIL [L6b stale_preview]: %', v_app; END IF;
    UPDATE finance.accounts SET account_number = NULL WHERE id = v_n;
    v_prep := finance.fn_statement_prepare(v_s);
    v_app := finance.fn_apply_bank_statement(v_s || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT account_number FROM finance.accounts WHERE id = v_n) IS DISTINCT FROM 'DE66500105174400000002'
       OR (SELECT balance FROM finance.account_balances WHERE account_id = v_n) <> 1000 THEN
        RAISE EXCEPTION 'FAIL [L6c gelernt ohne Buchung auf N26]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [L6 blocked + Fingerprint]';
    RAISE EXCEPTION USING ERRCODE = 'TR001', MESSAGE = 'Szenario zuruecksetzen';
EXCEPTION WHEN SQLSTATE 'TR001' THEN NULL;   -- nur das Zuruecksetzen, FAIL-Meldungen laufen durch
END $$;

-- ---------- S7: neues Konto (account_unknown) traegt den gedruckten Inhaber als Vorschlag ----------
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 90)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 90) + interval '1 month - 1 day')::date;
    v_s JSONB; v_prep JSONB;
BEGIN
    v_s := pg_temp.stmt(NULL, ps, pe, 500, jsonb_build_array(pg_temp.ln(ps + 2, -20, 'REWE', NULL)))
           - 'account_name' || jsonb_build_object('account_number', 'DE71500105174400000009');
    v_prep := finance.fn_statement_prepare(v_s || '{"account_holder":"ZWEISTEIN, MAXIMILIAN"}');
    IF v_prep->>'code' IS DISTINCT FROM 'account_unknown' OR v_prep->>'owner_person' IS DISTINCT FROM 'Maximilian Zweistein'
       OR (v_prep->>'owner_joint')::boolean THEN
        RAISE EXCEPTION 'FAIL [L7a Inhaber eine Person]: %', v_prep;
    END IF;
    v_prep := finance.fn_statement_prepare(v_s || '{"account_holder":"Maximilian und Erika Zweistein"}');
    IF v_prep->>'code' IS DISTINCT FROM 'account_unknown' OR v_prep ? 'owner_person' OR NOT (v_prep->>'owner_joint')::boolean THEN
        RAISE EXCEPTION 'FAIL [L7b Inhaber gemeinsam]: %', v_prep;
    END IF;
    v_prep := finance.fn_statement_prepare(v_s || '{"account_holder":"Firma Fremd GmbH"}');
    IF v_prep->>'code' IS DISTINCT FROM 'account_unknown' OR v_prep ? 'owner_person' OR v_prep ? 'owner_joint' THEN
        RAISE EXCEPTION 'FAIL [L7c fremder Inhaber]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [L7 Inhaber aus dem Auszug]';
END $$;
ROLLBACK;
