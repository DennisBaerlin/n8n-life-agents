-- ============================================================
-- test_fn_statement_prepare -- Rueckgabe-Felder fuer die Dauerauftrags-Erkennung auf einem bestaetigten Monat
--   already_covered und already_imported tragen account_id und balance_verified (Saldo-Probe), der Fingerprint und
--   die uebrigen Codes bleiben (test_bank_statement*). Erfundene IBAN.
-- ============================================================
BEGIN;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_acct INT;
    v_stmt JSONB;
    v_r    JSONB;
BEGIN
    v_acct := (finance.fn_create_account(jsonb_build_object('name', '__t_sp_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'account_number', 'DE89370400440532013000', 'opening_balance', 1000, 'opening_balance_date', (T - 40)::text))->>'account_id')::int;
    v_stmt := jsonb_build_object('account_number', 'DE89 3704 0044 0532 0130 00', 'currency', 'EUR',
        'period_start', (T - 70)::text, 'period_end', (T - 41)::text, 'opening_balance', 1100, 'closing_balance', 1000,
        'lines', jsonb_build_array(jsonb_build_object('date', (T - 60)::text, 'amount', -100, 'counterparty', 'Vermieter Test',
                                                      'counterparty_iban', '', 'creditor_id', '', 'mandate_ref', '', 'purpose', 'Miete')));
    -- Zeitraum endet vor dem Startbetrag -> already_covered (nach der Saldo-Probe, die hier stimmt)
    v_r := finance.fn_statement_prepare(v_stmt);
    IF v_r->>'code' IS DISTINCT FROM 'already_covered' OR (v_r->>'account_id')::int IS DISTINCT FROM v_acct
       OR (v_r->>'balance_verified')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [already_covered + account_id + balance_verified true]: %', v_r;
    END IF;
    -- bestaetigt bis period_end (last_reconciled_at)
    UPDATE finance.accounts SET last_reconciled_at = T - 41 WHERE id = v_acct;
    v_r := finance.fn_statement_prepare(v_stmt);
    IF v_r->>'code' IS DISTINCT FROM 'already_covered' OR (v_r->>'account_id')::int IS DISTINCT FROM v_acct
       OR (v_r->>'balance_verified')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [bestaetigt: already_covered + Felder]: %', v_r;
    END IF;
    -- bestaetigt: der Ruecksprung kommt vor der Saldo-Pflicht, die Probe steht im Feld
    v_r := finance.fn_statement_prepare(v_stmt || jsonb_build_object('closing_balance', 990));
    IF v_r->>'code' IS DISTINCT FROM 'already_covered' OR (v_r->>'balance_verified')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [already_covered, Saldo-Probe falsch -> balance_verified false]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [fn_statement_prepare already_covered traegt account_id + balance_verified]';
END $$;

-- Monats-Check nennt Versicherungen ohne Beitrag (Hinweis auf der Karte, nicht im Fingerprint: er bucht nichts).
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_stmt JSONB;
    v_r    JSONB;
    v_fp   TEXT;
    v_note JSONB;
BEGIN
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_sp_ins_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'account_number', 'DE02120300000000202051', 'opening_balance', 1000, 'opening_balance_date', (T - 40)::text));
    v_stmt := jsonb_build_object('account_number', 'DE02120300000000202051', 'currency', 'EUR',
        'period_start', (T - 30)::text, 'period_end', (T - 1)::text, 'opening_balance', 1000, 'closing_balance', 900,
        'lines', jsonb_build_array(jsonb_build_object('date', (T - 20)::text, 'amount', -100, 'counterparty', 'Laden Test',
                                                      'counterparty_iban', '', 'creditor_id', '', 'mandate_ref', '', 'purpose', 'Einkauf')));
    v_r := finance.fn_statement_prepare(v_stmt);
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l WHERE l->>'value' = 'finance.note.statement_insurance_premium_missing') THEN
        RAISE EXCEPTION 'FAIL [ohne Luecke kein Versicherungs-Hinweis]: %', v_r;
    END IF;
    v_fp := v_r->>'fingerprint';
    PERFORM finance.fn_create_insurance(jsonb_build_object('name', '__t_sp_ins_b__'));
    PERFORM finance.fn_create_insurance(jsonb_build_object('name', '__t_sp_ins_a__'));
    v_r := finance.fn_statement_prepare(v_stmt);
    SELECT l INTO v_note FROM jsonb_array_elements(v_r->'card_lines') l
     WHERE l->>'value' = 'finance.note.statement_insurance_premium_missing';
    IF v_note IS NULL OR v_note->'params'->>'names' NOT LIKE '%__t_sp_ins_a__, __t_sp_ins_b__%'
       OR v_r->>'fingerprint' IS DISTINCT FROM v_fp THEN
        RAISE EXCEPTION 'FAIL [Versicherung ohne Beitrag -> Hinweis mit Namen, Fingerprint gleich]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [fn_statement_prepare nennt Versicherungen ohne Beitrag]';
END $$;
ROLLBACK;

-- Durchstich Handbuchung: eine von Hand gebuchte Ausgabe, die der Auszug als Zeile fuehrt, ist erklaert (bereits
-- gebucht), kein unerklaerter Rest, kein Dubletten-Kandidat; apply bucht sie nicht doppelt. Eine Handbuchung ohne
-- Zeile bleibt als Abweichung sichtbar. Werte erfunden.
BEGIN;
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 120)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 120) + interval '1 month - 1 day')::date;
    a INT; v_tx INT; v_stmt JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_sph_giro__', 'account_type', 'cash', 'currency', 'EUR',
             'opening_balance', 500, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_tx := (finance.fn_book_transaction(jsonb_build_object('account_id', a, 'amount', 37.40, 'direction', 'outflow',
               'description', 'Buchladen Beispiel', 'transaction_date', (ps + 16)::text))->>'tx_id')::int;
    v_stmt := jsonb_build_object('account_name', '__t_sph_giro__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 500, 'closing_balance', 2012.60, 'lines', jsonb_build_array(
            jsonb_build_object('date', (ps + 16)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster'),
            jsonb_build_object('date', (pe - 1)::text, 'amount', 1550, 'counterparty', 'Arbeitgeber Beispiel', 'purpose', 'Lohn')));
    v_prep := finance.fn_statement_prepare(v_stmt);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true
       OR jsonb_array_length(v_prep->'already_booked') <> 1
       OR (v_prep->'already_booked'->0->>'transaction_id')::int IS DISTINCT FROM v_tx
       OR (v_prep->>'unmatched_out')::numeric <> 0 OR (v_prep->>'unmatched_in')::numeric <> 1550
       OR (v_prep->>'rest_unexplained')::numeric <> 0 OR (v_prep->>'lump')::numeric <> 1550
       OR v_prep->'difference_candidates' IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [MH1 Handbuchung erklaert]: %', v_prep;
    END IF;
    -- Karte: nach dem Block "Schon erfasst" beginnt der Schlussteil mit einer eigenen Ueberschrift; hier ohne Zinskorrektur
    -- und Hinweise, also direkt vor der Rest-Zeile (Geldzeile; ihr Label haengt vom Rest ab, hier Ungeklaerter Eingang)
    IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'card_lines') e
        WHERE e->>'kind' = 'heading' AND e->>'label' = 'finance.label.statement_other_heading') <> 1
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') e WHERE e->>'label' = 'finance.label.statement_booked')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') WITH ORDINALITY h(e, o)
                      JOIN jsonb_array_elements(v_prep->'card_lines') WITH ORDINALITY n(e, o) ON n.o = h.o + 1
                      WHERE h.e->>'label' = 'finance.label.statement_other_heading'
                        AND n.e->>'kind' = 'money' AND (n.e->>'value')::numeric = (v_prep->>'lump')::numeric) THEN
        RAISE EXCEPTION 'FAIL [MH1b Ueberschrift Alles andere nach Schon erfasst]: %', v_prep->'card_lines';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR (v_app->>'rest_unexplained')::numeric <> 0
       OR (SELECT count(*) FROM finance.transactions WHERE account_id = a AND amount = -37.40) <> 1
       OR (SELECT balance FROM finance.account_balances WHERE account_id = a) <> 2012.60 THEN
        RAISE EXCEPTION 'FAIL [MH2 apply]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [MH1-MH2 Handbuchung mit Auszugszeile]';

    -- Handbuchung ohne Zeile: bleibt unerklaert und als Kandidat sichtbar
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_sph_giro2__', 'account_type', 'cash', 'currency', 'EUR',
             'opening_balance', 500, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    v_tx := (finance.fn_book_transaction(jsonb_build_object('account_id', a, 'amount', 37.40, 'direction', 'outflow',
               'description', 'Buchladen Beispiel', 'transaction_date', (ps + 16)::text))->>'tx_id')::int;
    v_prep := finance.fn_statement_prepare(v_stmt || jsonb_build_object('account_name', '__t_sph_giro2__', 'closing_balance', 2050,
                  'lines', jsonb_build_array(v_stmt->'lines'->1)));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'already_booked') <> 0
       OR (v_prep->>'rest_unexplained')::numeric <> 37.40
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'difference_candidates') c
                      WHERE (c->>'transaction_id')::int = v_tx AND c->>'for' = 'unexplained') THEN
        RAISE EXCEPTION 'FAIL [MH3 Handbuchung ohne Zeile bleibt sichtbar]: %', v_prep;
    END IF;
    -- ohne Block davor bleibt die Karte wie bisher: keine Rest-Ueberschrift
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') e WHERE e->>'kind' = 'heading') THEN
        RAISE EXCEPTION 'FAIL [MH3b ohne Block keine Ueberschrift]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [MH3 Handbuchung ohne Zeile]';
END $$;
ROLLBACK;
