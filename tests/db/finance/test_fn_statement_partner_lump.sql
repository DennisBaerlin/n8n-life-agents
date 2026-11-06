-- ============================================================
-- test_fn_statement_partner_lump -- steckt eine Ueberweisung schon im Rest eines Auszugs des Gegenkontos?
--   Einheit: finance.fn_statement_partner_lump (exact / possible / NULL, Richtungsfenster, Verbrauch, Chat-Abgleich,
--   Datum des Gegenbeins). Durchstich: fn_statement_prepare + fn_apply_bank_statement in beiden Import-Reihenfolgen,
--   Folgeauszug, Ruecknahme, Altzustand (Sammelbetrag plus Bein am Folgetag). Werte erfunden.
-- ============================================================
BEGIN;

-- Auszug + Rest-Buchung direkt anlegen (Einheit prueft nur die Suche)
CREATE FUNCTION pg_temp.mk_acct(p_name text) RETURNS int LANGUAGE sql AS $$
    SELECT (finance.fn_create_account(jsonb_build_object('name', p_name, 'account_type', 'cash', 'currency', 'EUR'))->>'account_id')::int;
$$;
CREATE FUNCTION pg_temp.mk_stmt(p_acct int, p_from date, p_to date, p_in numeric, p_out numeric, p_rest numeric,
                                p_gap numeric DEFAULT NULL, p_prev date DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_id int;
BEGIN
    INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
        line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at, export_gap, balance_source)
    VALUES (p_acct, p_from, p_to, 0, 0, 'EUR', 1, 0, p_out, p_in, p_prev, p_gap,
            CASE WHEN p_gap IS NULL THEN 'printed' ELSE 'owner' END) RETURNING id INTO v_id;
    IF p_rest IS NOT NULL THEN
        INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description, bank_statement_id)
        VALUES (p_acct, p_rest, p_to, 'reconciliation', 'Monats-Check', v_id);
    END IF;
    UPDATE finance.accounts SET last_reconciled_at = p_to WHERE id = p_acct;
    RETURN v_id;
END;
$$;

DO $$
DECLARE
    ps  DATE := date_trunc('month', CURRENT_DATE - 120)::date;
    pe  DATE := (date_trunc('month', CURRENT_DATE - 120) + interval '1 month - 1 day')::date;
    a   INT; s INT; s2 INT;
    r   JSONB;
BEGIN
    -- U1: offene Summe = Betrag, Rest gleich -> exact aus der offenen Summe
    a := pg_temp.mk_acct('__t_pl_u1__'); s := pg_temp.mk_stmt(a, ps, pe, 100, 0, 100);
    r := finance.fn_statement_partner_lump(a, ps + 10, 100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'exact' OR r->>'source' IS DISTINCT FROM 'open' OR (r->>'statement_id')::int <> s
       OR (r->>'lump_amount')::numeric <> 100 OR (r->>'offset_date')::date <> ps + 10
       OR (r->>'lump_tx_id')::int IS NULL THEN
        RAISE EXCEPTION 'FAIL [U1 exact offene Summe]: %', r;
    END IF;

    -- U2: offene Summe = Betrag, Rest wegen offener Ausgaenge anders -> trotzdem exact
    a := pg_temp.mk_acct('__t_pl_u2__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 100, -30, 70);
    r := finance.fn_statement_partner_lump(a, ps + 10, 100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'exact' OR r->>'source' IS DISTINCT FROM 'open' THEN RAISE EXCEPTION 'FAIL [U2]: %', r; END IF;

    -- U3: der Netto-Rest allein beweist nichts: +900/-800 ergibt 100, ohne dass es eine solche Zeile gibt
    a := pg_temp.mk_acct('__t_pl_u3__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 900, -800, 100);
    r := finance.fn_statement_partner_lump(a, ps + 10, 100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'possible' THEN RAISE EXCEPTION 'FAIL [U3 Netto-Rest nie exact]: %', r; END IF;

    -- U4: Zeile nach dem Auszugsende + offene Eingaenge: normale Ueberweisung, kein Treffer (Monatsanfang)
    a := pg_temp.mk_acct('__t_pl_u4__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 700, 0, 700);
    r := finance.fn_statement_partner_lump(a, pe + 2, 100, '{}'::jsonb);
    IF r IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U4 nach dem Auszugsende kein Treffer]: %', r; END IF;

    -- U5: frueher blockierte Zeile steckt nur im Rest (rest_other) -> exact, auch nach dem Auszugsende (Zeile kommt an)
    a := pg_temp.mk_acct('__t_pl_u5__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 0, 0, -100);
    r := finance.fn_statement_partner_lump(a, pe + 2, -100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'exact' OR r->>'source' IS DISTINCT FROM 'other' THEN RAISE EXCEPTION 'FAIL [U5 rest_other exact]: %', r; END IF;

    -- U6: rest_other groesser als der Betrag -> possible, auch nach dem Auszugsende
    a := pg_temp.mk_acct('__t_pl_u6__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 0, 0, -150);
    r := finance.fn_statement_partner_lump(a, pe + 2, -100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'possible' THEN RAISE EXCEPTION 'FAIL [U6 rest_other groesser]: %', r; END IF;
    -- U6b: das Vorzeichen muss passen
    r := finance.fn_statement_partner_lump(a, pe + 2, 100, '{}'::jsonb);
    IF r IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U6b falsches Vorzeichen]: %', r; END IF;

    -- U7: offene Summen heben sich auf, keine Rest-Buchung -> nie exact, aber possible (sonst bliebe die Doppelung)
    a := pg_temp.mk_acct('__t_pl_u7__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 100, -100, NULL);
    r := finance.fn_statement_partner_lump(a, ps + 10, 100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'possible' THEN RAISE EXCEPTION 'FAIL [U7 ohne Rest-Buchung]: %', r; END IF;

    -- U8: Verbrauch innerhalb derselben Vorschau
    a := pg_temp.mk_acct('__t_pl_u8__'); s := pg_temp.mk_stmt(a, ps, pe, 100, 0, 100);
    r := finance.fn_statement_partner_lump(a, ps + 10, 50, jsonb_build_object(s::text, jsonb_build_object('open', 100)));
    IF r IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U8 offene Summe verbraucht]: %', r; END IF;

    -- U9: Saldo-Abgleich per Chat: nur possible, Betrag und Stichtag-Fenster zaehlen
    a := pg_temp.mk_acct('__t_pl_u9__');
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES (a, 100, pe, 'reconciliation', 'Saldo-Abgleich');
    UPDATE finance.accounts SET last_reconciled_at = pe WHERE id = a;
    r := finance.fn_statement_partner_lump(a, pe - 1, 100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'possible' OR r->>'source' IS DISTINCT FROM 'chat' THEN RAISE EXCEPTION 'FAIL [U9a Chat-Abgleich]: %', r; END IF;
    IF finance.fn_statement_partner_lump(a, pe - 1, 150, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U9b Betrag groesser]'; END IF;
    IF finance.fn_statement_partner_lump(a, pe + 1, 100, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U9c nach dem Stichtag]'; END IF;
    IF finance.fn_statement_partner_lump(a, pe - 6, 100, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U9d zu alt]'; END IF;

    -- U10: Vormerkung (export_gap) ist keine Zeile: Rest -100 ohne offene Summe -> kein Treffer
    a := pg_temp.mk_acct('__t_pl_u10__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 0, 0, -100, -100);
    r := finance.fn_statement_partner_lump(a, ps + 10, -100, '{}'::jsonb);
    IF r IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U10 Vormerkung]: %', r; END IF;

    -- U11: Gegenbein nie vor einem frueheren Abgleich und nie hinter das Auszugsende
    a := pg_temp.mk_acct('__t_pl_u11__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 100, 0, 100, NULL, ps + 14);
    r := finance.fn_statement_partner_lump(a, ps + 13, 100, '{}'::jsonb);
    IF (r->>'offset_date')::date <> ps + 15 THEN RAISE EXCEPTION 'FAIL [U11a frueherer Abgleich]: %', r; END IF;
    r := finance.fn_statement_partner_lump(a, pe + 1, 100, '{}'::jsonb);
    IF (r->>'offset_date')::date <> pe THEN RAISE EXCEPTION 'FAIL [U11b Auszugsende]: %', r; END IF;

    -- U12: Richtungsfenster. Zeile geht ab (Bein +): [ps-5, pe+1]; Zeile kommt an (Bein -): [ps-1, pe+5]
    a := pg_temp.mk_acct('__t_pl_u12a__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 100, 0, 100);
    IF finance.fn_statement_partner_lump(a, ps - 5, 100, '{}'::jsonb)->>'match' IS DISTINCT FROM 'exact' THEN RAISE EXCEPTION 'FAIL [U12a]'; END IF;
    IF finance.fn_statement_partner_lump(a, ps - 6, 100, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U12b]'; END IF;
    IF finance.fn_statement_partner_lump(a, pe + 2, 100, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U12c]'; END IF;
    a := pg_temp.mk_acct('__t_pl_u12d__'); PERFORM pg_temp.mk_stmt(a, ps, pe, 0, -100, -100);
    IF finance.fn_statement_partner_lump(a, pe + 5, -100, '{}'::jsonb)->>'match' IS DISTINCT FROM 'exact' THEN RAISE EXCEPTION 'FAIL [U12d]'; END IF;
    IF finance.fn_statement_partner_lump(a, pe + 6, -100, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U12e]'; END IF;
    IF finance.fn_statement_partner_lump(a, ps - 2, -100, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U12f]'; END IF;

    -- U13: zwei Auszuege treffen exakt, die Zeile liegt in keinem -> nicht raten; liegt sie in einem, gilt der
    a := pg_temp.mk_acct('__t_pl_u13__');
    s  := pg_temp.mk_stmt(a, ps, ps + 9, 0, -100, -100);
    s2 := pg_temp.mk_stmt(a, ps + 12, pe, 0, -100, -100);
    r := finance.fn_statement_partner_lump(a, ps + 11, -100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'possible' THEN RAISE EXCEPTION 'FAIL [U13a zwei Treffer ausserhalb]: %', r; END IF;
    r := finance.fn_statement_partner_lump(a, ps + 12, -100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'exact' OR (r->>'statement_id')::int <> s2 THEN RAISE EXCEPTION 'FAIL [U13b Zeile im Auszug]: %', r; END IF;
    r := finance.fn_statement_partner_lump(a, ps + 9, -100, '{}'::jsonb);
    IF r->>'match' IS DISTINCT FROM 'exact' OR (r->>'statement_id')::int <> s THEN RAISE EXCEPTION 'FAIL [U13c Zeile im aelteren Auszug]: %', r; END IF;

    -- U14: kein Auszug, kein Abgleich -> nichts
    a := pg_temp.mk_acct('__t_pl_u14__');
    IF finance.fn_statement_partner_lump(a, ps, 100, '{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [U14]'; END IF;
    RAISE NOTICE 'PASS [U1-U14 Suche nach dem Sammelbetrag]';
END $$;

-- ---------- Durchstich ----------
-- Zwei Konten A/B je 1000 am Vortag des Zeitraums. Je Fall neue Konten (Helfer legt beide an).
CREATE FUNCTION pg_temp.mk_pair(p_tag text, p_ps date, OUT a int, OUT b int) LANGUAGE plpgsql AS $$
BEGIN
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_a_' || p_tag, 'account_type', 'cash', 'currency', 'EUR'))->>'account_id')::int;
    b := (finance.fn_create_account(jsonb_build_object('name', '__t_b_' || p_tag, 'account_type', 'cash', 'currency', 'EUR'))->>'account_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (a, 1000, p_ps - 20, 'other'), (b, 1000, p_ps - 20, 'other');
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', a, 'confirmed_balance', 1000, 'reconciliation_date', (p_ps - 1)::text));
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', b, 'confirmed_balance', 1000, 'reconciliation_date', (p_ps - 1)::text));
    -- Kontonummern fuer Stufe T (eindeutig je Paar)
    UPDATE finance.accounts SET account_number = 'TESTA' || a WHERE id = a;
    UPDATE finance.accounts SET account_number = 'TESTB' || b WHERE id = b;
END;
$$;
CREATE FUNCTION pg_temp.stmt(p_name text, p_from date, p_to date, p_open numeric, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object('account_name', p_name, 'currency', 'EUR', 'period_start', p_from, 'period_end', p_to,
               'opening_balance', p_open,
               'closing_balance', p_open + COALESCE((SELECT sum((l->>'amount')::numeric) FROM jsonb_array_elements(p_lines) l), 0),
               'lines', p_lines);
$$;
CREATE FUNCTION pg_temp.line(p_date date, p_amount numeric, p_iban text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object('date', p_date, 'amount', p_amount, 'counterparty', 'Jemand', 'counterparty_iban', p_iban, 'purpose', 'Text');
$$;
CREATE FUNCTION pg_temp.apply(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_prep jsonb;
BEGIN
    v_prep := finance.fn_statement_prepare(p);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL prepare: %', v_prep; END IF;
    RETURN finance.fn_apply_bank_statement(p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
END;
$$;
CREATE FUNCTION pg_temp.bal(p_acct int) RETURNS numeric LANGUAGE sql AS $$
    SELECT balance FROM finance.account_balances WHERE account_id = p_acct;
$$;

DO $$
DECLARE
    ps  DATE := date_trunc('month', CURRENT_DATE - 120)::date;
    pe  DATE := (date_trunc('month', CURRENT_DATE - 120) + interval '1 month - 1 day')::date;
    p2e DATE;
    a INT; b INT;
    na TEXT; nb TEXT;
    ia TEXT; ib TEXT;
    v_prep JSONB; v_app JSONB; v_res JSONB; v_sa JSONB; v_sb JSONB;
    v_leg_tx INT;
BEGIN
    p2e := (date_trunc('month', pe + 1) + interval '1 month - 1 day')::date;

    -- ---------- S1: Empfaenger B zuerst (Absender unbekannt), dann A: Rest = Betrag, Zeile am letzten Tag ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s1', ps) x;
    na := '__t_a_s1'; nb := '__t_b_s1'; ib := 'TESTB' || b;
    v_app := pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe, 100))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR (v_app->>'rest_inflow')::numeric <> 100 THEN RAISE EXCEPTION 'FAIL [S1a B]: %', v_app; END IF;
    v_sa := pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe, -100, ib)));
    v_prep := finance.fn_statement_prepare(v_sa);
    IF v_prep->'matched'->0->'partner_lump'->>'match' IS DISTINCT FROM 'exact' OR v_prep->'matched'->0 ? 'partner_date'
       OR jsonb_array_length(v_prep->'blocked') <> 0 THEN
        RAISE EXCEPTION 'FAIL [S1b Vorschau: Treffer statt Unterwegs]: %', v_prep->'matched';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'value' = 'finance.note.statement_lump_offset')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_in_transit') THEN
        RAISE EXCEPTION 'FAIL [S1c Karte]: %', v_prep->'card_lines';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_sa || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [S1d apply A]: %', v_app; END IF;
    IF pg_temp.bal(a) <> 900 OR pg_temp.bal(b) <> 1100 THEN RAISE EXCEPTION 'FAIL [S1e Salden]: A % B %', pg_temp.bal(a), pg_temp.bal(b); END IF;
    IF (SELECT count(*) FROM finance.transactions WHERE account_id = b AND category = 'reconciliation' AND transaction_date = pe) <> 0 THEN
        RAISE EXCEPTION 'FAIL [S1f Rest auf B weg]';
    END IF;
    IF (SELECT transaction_date FROM finance.transactions WHERE account_id = b AND category = 'transfer') <> pe
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = a AND category = 'transfer') <> pe THEN
        RAISE EXCEPTION 'FAIL [S1g Bein nicht hinter dem bestaetigten Zeitraum]';
    END IF;
    IF (SELECT unmatched_in FROM finance.bank_statements WHERE account_id = b) <> 0
       OR (SELECT last_reconciled_balance FROM finance.accounts WHERE id = b) <> 1100
       OR finance.fn_get_balance_as_of(b, pe) <> 1100 THEN
        RAISE EXCEPTION 'FAIL [S1h Aggregat + bestaetigter Stand]';
    END IF;
    -- Rueckgabe: je Verrechnung Konto, Betrag, Datum, Rest und Saldo danach; transfers[] markiert sie
    IF jsonb_array_length(v_app->'lump_offsets') <> 1 OR v_app->'lump_offsets'->0->>'account_name' <> nb
       OR (v_app->'lump_offsets'->0->>'amount')::numeric <> 100 OR (v_app->'lump_offsets'->0->>'date')::date <> pe
       OR (v_app->'lump_offsets'->0->>'rest_after')::numeric <> 0 OR (v_app->'lump_offsets'->0->>'balance_after')::numeric <> 1100
       OR (v_app->'transfers'->0->>'from_lump')::boolean IS DISTINCT FROM true
       OR jsonb_array_length(v_app->'transfers_unclear') <> 0 THEN
        RAISE EXCEPTION 'FAIL [S1i Rueckgabe]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [S1 B zuerst, Rest = Betrag]';

    -- ---------- S2: umgekehrte Reihenfolge: Absender A zuerst (Empfaenger unbekannt), dann B ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s2', ps) x;
    na := '__t_a_s2'; nb := '__t_b_s2'; ia := 'TESTA' || a;
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 10, -100))));
    IF (v_app->>'rest_outflow')::numeric <> 100 THEN RAISE EXCEPTION 'FAIL [S2a A]: %', v_app; END IF;
    v_app := pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 11, 100, ia))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(a) <> 900 OR pg_temp.bal(b) <> 1100 THEN
        RAISE EXCEPTION 'FAIL [S2b Salden wie S1]: % A % B %', v_app, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    IF (SELECT transaction_date FROM finance.transactions WHERE account_id = a AND category = 'transfer') <> ps + 11
       OR (SELECT unmatched_out FROM finance.bank_statements WHERE account_id = a) <> 0
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = a AND category = 'reconciliation' AND transaction_date = pe) THEN
        RAISE EXCEPTION 'FAIL [S2c Verrechnung auf A]';
    END IF;
    RAISE NOTICE 'PASS [S2 A zuerst]';

    -- ---------- S3: offene Summe = Betrag, Rest anders; der Rest bleibt mit den uebrigen Zeilen stehen ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s3', ps) x;
    na := '__t_a_s3'; nb := '__t_b_s3'; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, 100), pg_temp.line(ps + 4, -30))));
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, -100, ib))));
    IF pg_temp.bal(a) <> 900 OR pg_temp.bal(b) <> 1070
       OR (SELECT amount FROM finance.transactions WHERE account_id = b AND category = 'reconciliation' AND transaction_date = pe) <> -30
       OR (SELECT unmatched_in FROM finance.bank_statements WHERE account_id = b) <> 0
       OR (SELECT unmatched_out FROM finance.bank_statements WHERE account_id = b) <> -30
       OR (v_app->'lump_offsets'->0->>'rest_after')::numeric <> -30 THEN
        RAISE EXCEPTION 'FAIL [S3 Rest bleibt -30]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [S3 Rest bleibt mit den uebrigen Zeilen]';

    -- ---------- S4: unklar: +900/-800 auf B. Kein Uebertrag, beide Staende stimmen, Fall steht als Daten da ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s4', ps) x;
    na := '__t_a_s4'; nb := '__t_b_s4'; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, 900), pg_temp.line(ps + 4, -800))));
    v_sa := pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, -100, ib)));
    v_prep := finance.fn_statement_prepare(v_sa);
    IF v_prep->'blocked'->0->>'reason' IS DISTINCT FROM 'partner_lump_possible' OR jsonb_array_length(v_prep->'matched') <> 0
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'value' = 'finance.note.statement_partner_lump_possible') THEN
        RAISE EXCEPTION 'FAIL [S4a Vorschau]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_sa || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF pg_temp.bal(a) <> 900 OR pg_temp.bal(b) <> 1100
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id IN (a, b) AND category = 'transfer')
       OR jsonb_array_length(v_app->'transfers_unclear') <> 1 OR v_app->'transfers_unclear'->0->>'account_name' <> nb
       OR (v_app->'transfers_unclear'->0->>'amount')::numeric <> -100 OR (v_app->'transfers_unclear'->0->>'date')::date <> ps + 3
       OR jsonb_array_length(v_app->'lump_offsets') <> 0 THEN
        RAISE EXCEPTION 'FAIL [S4b nichts gebucht, Fall gemeldet]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [S4 unklar: kein Uebertrag]';

    -- ---------- S5: zwei gleiche Zeilen, nur eine steckt im Rest: Verbrauch; die zweite ist wirklich unterwegs ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s5', ps) x;
    na := '__t_a_s5'; nb := '__t_b_s5'; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe - 1, 100))));
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe - 1, -100, ib), pg_temp.line(pe, -100, ib))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(a) <> 800 OR pg_temp.bal(b) <> 1200
       OR jsonb_array_length(v_app->'lump_offsets') <> 1
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = b AND category = 'transfer' AND transaction_date = pe + 1) <> 1 THEN
        RAISE EXCEPTION 'FAIL [S5 eine verrechnet, eine unterwegs]: % A % B %', v_app, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    RAISE NOTICE 'PASS [S5 Verbrauch]';

    -- ---------- S6: oneoff-CHECK: Einzelzeile ueber der Grenze wird verrechnet ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s6', ps) x;
    na := '__t_a_s6'; nb := '__t_b_s6'; ia := 'TESTA' || a;
    PERFORM pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, -250))));
    IF (SELECT oneoff_out FROM finance.bank_statements WHERE account_id = a) <> -250 THEN RAISE EXCEPTION 'FAIL [S6a Vorbedingung oneoff]'; END IF;
    v_app := pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, 250, ia))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT unmatched_out FROM finance.bank_statements WHERE account_id = a) <> 0
       OR (SELECT oneoff_out FROM finance.bank_statements WHERE account_id = a) <> 0
       OR pg_temp.bal(a) <> 750 OR pg_temp.bal(b) <> 1250 THEN
        RAISE EXCEPTION 'FAIL [S6b oneoff mitgezogen]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [S6 oneoff]';

    -- ---------- S7: frueherer Chat-Abgleich vor dem Zeitraum: der bestaetigte Stand dort bleibt unberuehrt ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s7', ps) x;
    na := '__t_a_s7'; nb := '__t_b_s7'; ib := 'TESTB' || b;
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', b, 'confirmed_balance', 1000, 'reconciliation_date', (ps + 14)::text));
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 15, 100))));
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 13, -100, ib))));
    IF (SELECT transaction_date FROM finance.transactions WHERE account_id = b AND category = 'transfer') <> ps + 15
       OR finance.fn_get_balance_as_of(b, ps + 14) <> 1000 OR pg_temp.bal(b) <> 1100 THEN
        RAISE EXCEPTION 'FAIL [S7 Stand am frueheren Abgleich]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [S7 frueherer Abgleich]';

    -- ---------- S8: Ueberweisung nach Bs Auszugsende, offene Eingaenge auf B: normal gebucht wie heute ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s8', ps) x;
    na := '__t_a_s8'; nb := '__t_b_s8'; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, 700))));
    v_app := pg_temp.apply(pg_temp.stmt(na, pe - 1, pe + 3, 1000, jsonb_build_array(pg_temp.line(pe + 2, -100, ib))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = b AND category = 'transfer') <> pe + 2
       OR pg_temp.bal(b) <> 1800 OR jsonb_array_length(v_app->'transfers_unclear') <> 0 THEN
        RAISE EXCEPTION 'FAIL [S8 Monatsanfang normal gebucht]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [S8 Ueberweisung nach dem Auszugsende]';

    -- ---------- S9: Spiegel: Zeile auf A blockiert (unklar), kam bei B erst im Folgemonat an -> kein zweiter Transfer ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s9', ps) x;
    na := '__t_a_s9'; nb := '__t_b_s9'; ia := 'TESTA' || a; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, 700))));
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe, -100, ib))));
    IF jsonb_array_length(v_app->'transfers_unclear') <> 1 OR pg_temp.bal(a) <> 900 THEN RAISE EXCEPTION 'FAIL [S9a]: %', v_app; END IF;
    v_app := pg_temp.apply(pg_temp.stmt(nb, pe + 1, p2e, 1700, jsonb_build_array(pg_temp.line(pe + 2, 100, ia))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(a) <> 900 OR pg_temp.bal(b) <> 1800
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = a AND category = 'transfer') <> 1
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = a AND category = 'transfer') <> pe
       OR finance.fn_get_balance_as_of(a, pe) <> 900 THEN
        RAISE EXCEPTION 'FAIL [S9b Folgeauszug verrechnet mit As Rest]: % A % B %', v_app, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    RAISE NOTICE 'PASS [S9 Spiegel-Fall]';

    -- ---------- S10: Zufallstreffer: B hat +100 von Dritten, As Ueberweisung kommt bei B erst danach an ----------
    --   Der Folgeauszug von B bucht nie einen zweiten Transfer (pending_pair auf dem bestaetigten Bein), die Salden stimmen.
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s10', ps) x;
    na := '__t_a_s10'; nb := '__t_b_s10'; ia := 'TESTA' || a; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe - 1, 100))));
    PERFORM pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe - 1, -100, ib))));
    v_sb := pg_temp.stmt(nb, pe + 1, p2e, 1100, jsonb_build_array(pg_temp.line(pe + 2, 100, ia)));
    v_prep := finance.fn_statement_prepare(v_sb);
    IF v_prep->'blocked'->0->>'reason' IS DISTINCT FROM 'pending_pair' OR jsonb_array_length(v_prep->'matched') <> 0 THEN
        RAISE EXCEPTION 'FAIL [S10a kein zweiter Transfer]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_sb || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF pg_temp.bal(a) <> 900 OR pg_temp.bal(b) <> 1200 THEN RAISE EXCEPTION 'FAIL [S10b Salden]: A % B %', pg_temp.bal(a), pg_temp.bal(b); END IF;
    RAISE NOTICE 'PASS [S10 Zufallstreffer]';

    -- ---------- S11: Ruecknahme und Wiedereinspielen ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s11', ps) x;
    na := '__t_a_s11'; nb := '__t_b_s11'; ib := 'TESTB' || b;
    v_sb := pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe, 100)));
    v_sa := pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe, -100, ib)));
    PERFORM pg_temp.apply(v_sb);
    PERFORM pg_temp.apply(v_sa);
    -- Einzel-Storno der Gruppe: das Gegenbein steckt in Bs bestaetigtem Stand
    SELECT id INTO v_leg_tx FROM finance.transactions WHERE account_id = a AND category = 'transfer';
    v_res := finance.fn_void_transaction(jsonb_build_object('transaction_id', v_leg_tx));
    IF v_res->>'code' IS DISTINCT FROM 'partner_reconciled' OR v_res->>'account' IS DISTINCT FROM nb OR pg_temp.bal(b) <> 1100 THEN
        RAISE EXCEPTION 'FAIL [S11a Storno-Schutz]: %', v_res;
    END IF;
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', a));
    IF v_res->>'code' IS DISTINCT FROM 'partner_reconciled' THEN RAISE EXCEPTION 'FAIL [S11b A gesperrt]: %', v_res; END IF;
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', b));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(b) <> 1100 THEN RAISE EXCEPTION 'FAIL [S11c B zurueck]: %', v_res; END IF;
    -- B erneut: trifft die Gruppe ueber Stufe 0, kein Rest
    v_prep := finance.fn_statement_prepare(v_sb);
    IF jsonb_array_length(v_prep->'already_booked') <> 1 OR (v_prep->>'lump')::numeric <> 0 THEN RAISE EXCEPTION 'FAIL [S11d B erneut]: %', v_prep; END IF;
    -- oder erst ganz zurueck: A geht jetzt, beide stehen wieder auf dem Ausgangsstand
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', a));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(a) <> 1000 OR pg_temp.bal(b) <> 1000 THEN
        RAISE EXCEPTION 'FAIL [S11e beide zurueck]: % A % B %', v_res, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    -- Wiedereinspielen in beiden Reihenfolgen ergibt dieselben Staende
    PERFORM pg_temp.apply(v_sb);
    PERFORM pg_temp.apply(v_sa);
    IF pg_temp.bal(a) <> 900 OR pg_temp.bal(b) <> 1100 THEN RAISE EXCEPTION 'FAIL [S11f erneut]: A % B %', pg_temp.bal(a), pg_temp.bal(b); END IF;
    RAISE NOTICE 'PASS [S11 Ruecknahme und Wiedereinspielen]';

    -- ---------- S12: Altzustand (Sammelbetrag auf B plus Bein am Folgetag): A zuruecknehmen und neu einspielen ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s12', ps) x;
    na := '__t_a_s12'; nb := '__t_b_s12'; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(pe, 100))));
    -- so hat die alte Version gebucht: Transfer unterwegs, Bein auf B am Tag nach dessen Abgleich
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 2, -30))));
    v_res := finance.fn_book_transfer(jsonb_build_object('from_account_id', a, 'to_account_id', b, 'amount', 100,
                 'transaction_date', (pe + 1)::text, 'from_account_name', na, 'to_account_name', nb, 'purpose', 'Monats-Check'));
    UPDATE finance.transactions SET transaction_date = pe, bank_statement_id = (v_app->>'statement_id')::int
    WHERE id = (v_res->>'debit_tx_id')::int;
    UPDATE finance.transactions SET bank_statement_id = (v_app->>'statement_id')::int WHERE id = (v_res->>'credit_tx_id')::int;
    UPDATE finance.accounts SET last_reconciled_balance = 870 WHERE id = a;
    UPDATE finance.bank_statements SET closing_balance = 870 WHERE account_id = a;
    IF pg_temp.bal(b) <> 1200 THEN RAISE EXCEPTION 'FAIL [S12a Altzustand]: %', pg_temp.bal(b); END IF;
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', a));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(b) <> 1100 THEN RAISE EXCEPTION 'FAIL [S12b Ruecknahme]: % B %', v_res, pg_temp.bal(b); END IF;
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 2, -30), pg_temp.line(pe, -100, ib))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(a) <> 870 OR pg_temp.bal(b) <> 1100
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = b AND category = 'reconciliation' AND transaction_date = pe)
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = b AND category = 'transfer') <> pe THEN
        RAISE EXCEPTION 'FAIL [S12c sauber nach Neu-Import]: % A % B %', v_app, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    RAISE NOTICE 'PASS [S12 Altzustand korrigiert]';

    -- ---------- S13: Rest-Betrag getrennt (Fund 4): Eingaenge, Ausgaenge und Sonstiges ergeben auf den Cent den Rest ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s13', ps) x;
    na := '__t_a_s13'; nb := '__t_b_s13'; ib := 'TESTB' || b;
    -- A: +900/-800 offen, dazu eine erkannte, nicht buchbare Zeile -40 (Gegenkonto weit nach der Zeile bestaetigt)
    PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', b, 'confirmed_balance', 1000, 'reconciliation_date', pe::text));
    v_sa := pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 2, 900), pg_temp.line(ps + 3, -800), pg_temp.line(ps + 4, -40, ib)));
    v_prep := finance.fn_statement_prepare(v_sa);
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' = 'finance.label.statement_rest_net' AND (c->>'value')::numeric = 60)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'value' = 'finance.note.statement_rest_split')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'label' IN ('finance.label.statement_unexplained_in', 'finance.label.statement_everyday')) THEN
        RAISE EXCEPTION 'FAIL [S13a Karte: Saldo statt Eingang]: %', v_prep->'card_lines';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_sa || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'rest_inflow')::numeric <> 60 OR (v_app->>'unmatched_in')::numeric <> 900 OR (v_app->>'unmatched_out')::numeric <> -800
       OR (v_app->>'rest_other')::numeric <> -40 THEN
        RAISE EXCEPTION 'FAIL [S13b Rueckgabe]: %', v_app;
    END IF;
    IF (v_app->>'rest_unexplained')::numeric <> 0 THEN RAISE EXCEPTION 'FAIL [S13c die blockierte Zeile ist erklaert]: %', v_app; END IF;
    RAISE NOTICE 'PASS [S13 Rest getrennt]';

    -- ---------- S14: der Rest laeuft durch 0: die zweite Verrechnung desselben Auszugs mindert ihn trotzdem ----------
    --   B: +100 und -40 offen, dazu eine Buchung -40 ohne Zeile -> Rest 100, Rest-Anteil ausserhalb der offenen Summen +40
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s14', ps) x;
    na := '__t_a_s14'; nb := '__t_b_s14'; ib := 'TESTB' || b;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES (b, -40, ps + 5, 'other', 'ohne Zeile');
    v_app := pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, 100), pg_temp.line(ps + 4, -40))));
    IF (v_app->>'lump_amount')::numeric <> 100 THEN RAISE EXCEPTION 'FAIL [S14a Vorbedingung Rest 100]: %', v_app; END IF;
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, -100, ib), pg_temp.line(ps + 6, -40, ib))));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_app->'lump_offsets') <> 2
       OR pg_temp.bal(a) <> 860 OR pg_temp.bal(b) <> 1060
       OR (SELECT amount FROM finance.transactions WHERE account_id = b AND category = 'reconciliation' AND transaction_date = pe) <> -40 THEN
        RAISE EXCEPTION 'FAIL [S14b Rest durch 0]: % A % B %', v_app, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    RAISE NOTICE 'PASS [S14 Rest laeuft durch 0]';

    -- ---------- S15: Auszahlung mit Gebuehr: das Bein auf dem Gegenkonto ist Betrag minus Gebuehr ----------
    SELECT x.a, x.b INTO a, b FROM pg_temp.mk_pair('s15', ps) x;
    na := '__t_a_s15'; nb := '__t_b_s15'; ib := 'TESTB' || b;
    PERFORM pg_temp.apply(pg_temp.stmt(nb, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, 100))));
    v_app := pg_temp.apply(pg_temp.stmt(na, ps, pe, 1000, jsonb_build_array(pg_temp.line(ps + 3, -101, ib) || '{"transfer_fee":1}'::jsonb)));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(a) <> 899 OR pg_temp.bal(b) <> 1100
       OR (v_app->'lump_offsets'->0->>'amount')::numeric <> 100
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = a AND category = 'fee' AND amount = -1) <> 1
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = b AND category = 'reconciliation' AND transaction_date = pe) THEN
        RAISE EXCEPTION 'FAIL [S15 Gebuehr]: % A % B %', v_app, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    RAISE NOTICE 'PASS [S15 Gebuehr]';
END $$;

-- ---------- Durchstich mit Bank-Export (N26-Profil, App-Stand) ----------
CREATE FUNCTION pg_temp.n26_row(p_d date, p_partner text, p_iban text, p_type text, p_ref text, p_amt text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text, p_d::text, p_partner, p_iban, p_type, p_ref, 'Hauptkonto', p_amt, '', '', '');
$$;
DO $$
DECLARE
    T     DATE := core.fn_today();
    v_hdr JSONB := '["Booking Date","Value Date","Partner Name","Partner Iban","Type","Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"]';
    a INT; b INT;
    v_p JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_pl_n26__', 'account_type', 'cash', 'currency', 'EUR', 'bank', 'N26',
              'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    b := (finance.fn_create_account(jsonb_build_object('name', '__t_pl_ziel__', 'account_type', 'cash', 'currency', 'EUR',
              'account_number', 'DE89370400440532013000', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    -- B zuerst: die 100 landen im Rest (ohne Gegen-IBAN), Auszug bis vorgestern
    PERFORM pg_temp.apply(pg_temp.stmt('__t_pl_ziel__', T - 19, T - 2, 1000, jsonb_build_array(pg_temp.line(T - 2, 100))));
    -- A per Export: Ueberweisung an Bs IBAN, dazu eine vorgemerkte Kartenzahlung -50, die die App schon abzieht
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_pl_n26__', 'closing_balance', '850,00',
               'table', jsonb_build_object('rows', jsonb_build_array(v_hdr)
                   || jsonb_build_array(pg_temp.n26_row(T - 2, 'Ich', 'DE89 3704 0044 0532 0130 00', 'Debit Transfer', 'Umbuchung', '-100.00'))));
    v_prep := finance.fn_statement_prepare(v_p);
    IF v_prep->'matched'->0->'partner_lump'->>'match' IS DISTINCT FROM 'exact' OR (v_prep->>'export_gap')::numeric <> -50 THEN
        RAISE EXCEPTION 'FAIL [F1 Vorschau]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bal(a) <> 850 OR pg_temp.bal(b) <> 1100
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = b AND category = 'reconciliation')
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = b AND category = 'transfer') <> T - 2 THEN
        RAISE EXCEPTION 'FAIL [F2 Salden]: % A % B %', v_app, pg_temp.bal(a), pg_temp.bal(b);
    END IF;
    -- die Vormerkung steckt im Rest, ist aber erklaert: keine Abweichung, nach der der Agent suchen muesste
    IF (v_app->>'rest_outflow')::numeric <> 50 OR (v_app->>'rest_other')::numeric <> -50 OR (v_app->>'rest_unexplained')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [F3 Vormerkung erklaert]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [F1-F3 Bank-Export]';
END $$;
ROLLBACK;
