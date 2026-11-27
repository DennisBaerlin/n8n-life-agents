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

-- Einnahme mit Schluessel ueber 150 % des Solls (Gehalt plus Sonderzahlung in einer Ueberweisung): das Gehalt gilt nicht
-- als fehlend, die Zeile wird mit dem Ist-Betrag gebucht, nichts davon steht im Rest.
-- Plan-Anpassung (2. gleicher Ist-Betrag): die Kartenzeile nennt bisher und neu.
BEGIN;
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 120)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 120) + interval '1 month - 1 day')::date;
    a INT; r INT; v_stmt JSONB; v_prep JSONB; v_app JSONB; v_res JSONB;
BEGIN
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_spx_giro__', 'account_type', 'cash', 'currency', 'EUR',
             'opening_balance', 500, 'opening_balance_date', (ps - 1)::text))->>'account_id')::int;
    r := finance.fn_add_recurring_payment(a, 2400, 'Lohn Beispielfirma', 1::smallint, 'month'::finance.schedule_unit, 25::smallint,
             ps, ps, NULL, NULL, NULL);
    INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
    VALUES (r, 'counterparty_iban', 'DE02120300000000202051', 'user');
    v_stmt := jsonb_build_object('account_name', '__t_spx_giro__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 500, 'closing_balance', 4700, 'lines', jsonb_build_array(
            jsonb_build_object('date', (ps + 24)::text, 'amount', 4200, 'counterparty', 'Arbeitgeber Muster',
                               'counterparty_iban', 'DE02 1203 0000 0000 2020 51', 'purpose', 'Bezuege')));
    v_prep := finance.fn_statement_prepare(v_stmt);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'matched') m
                      WHERE (m->>'recurring_payment_id')::int = r AND (m->>'amount')::numeric = 4200)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE (x->>'recurring_payment_id')::int = r)
       OR (v_prep->>'unmatched_in')::numeric <> 0 OR (v_prep->>'lump')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [SX1 Gehalt plus Sonderzahlung: zugeordnet, nicht fehlend, kein Rest]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR (v_app->>'lump_amount')::numeric IS DISTINCT FROM 0
       OR (SELECT amount FROM finance.transactions WHERE recurring_payment_id = r AND recurring_due_date = ps + 24) IS DISTINCT FROM 4200
       OR EXISTS (SELECT 1 FROM finance.recurring_payment_skips WHERE recurring_payment_id = r AND due_date = ps + 24)
       OR (SELECT balance FROM finance.account_balances WHERE account_id = a) <> 4700 THEN
        RAISE EXCEPTION 'FAIL [SX2 apply bucht den Ist-Betrag aufs Vorkommen, kein Skip]: %', v_app;
    END IF;
    RAISE NOTICE 'PASS [SX1-SX2 Gehalt plus Sonderzahlung ueber 150 %% in einer Ueberweisung]';

    -- Plan-Anpassung: Vormonat schon 2472, jetzt wieder 2472 -> Zeile "bisher 2400 -> neu 2472"
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_spx_giro2__', 'account_type', 'cash', 'currency', 'EUR',
             'opening_balance', 500, 'opening_balance_date', (ps - 40)::text))->>'account_id')::int;
    r := finance.fn_add_recurring_payment(a, 2400, 'Lohn Beispielfirma', 1::smallint, 'month'::finance.schedule_unit, 25::smallint,
             (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
    INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
    VALUES (r, 'counterparty_iban', 'DE02120300000000202051', 'user');
    v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r,
                 'due_date', (ps - interval '1 month' + interval '24 days')::date, 'amount', 2472));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP Vormonat: %', v_res; END IF;
    v_stmt := jsonb_build_object('account_name', '__t_spx_giro2__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 2972, 'closing_balance', 5444, 'lines', jsonb_build_array(
            jsonb_build_object('date', (ps + 24)::text, 'amount', 2472, 'counterparty', 'Arbeitgeber Muster',
                               'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
    v_prep := finance.fn_statement_prepare(v_stmt);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'plan_adjustments') <> 1 THEN
        RAISE EXCEPTION 'SETUP Plan-Anpassung erwartet: %', v_prep;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c
                   WHERE c->'value'->>'value' = 'finance.tpl.statement_plan_adjust_row'
                     AND (c->'value'->'params'->'planned'->>'value')::numeric = 2400
                     AND (c->'value'->'params'->'amount'->>'value')::numeric = 2472) THEN
        RAISE EXCEPTION 'FAIL [SX3 Kartenzeile Plan wird angepasst nennt bisher und neu]: %', v_prep->'card_lines';
    END IF;
    RAISE NOTICE 'PASS [SX3 Kartenzeile Plan-Anpassung bisher -> neu]';

    -- Zweimal derselbe Betrag ueber 150 % (Stufe C, Soll plus Zusatz): keine Plan-Anpassung
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_spx_giro3__', 'account_type', 'cash', 'currency', 'EUR',
             'opening_balance', 500, 'opening_balance_date', (ps - 40)::text))->>'account_id')::int;
    r := finance.fn_add_recurring_payment(a, 2400, 'Lohn Beispielfirma', 1::smallint, 'month'::finance.schedule_unit, 25::smallint,
             (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
    INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
    VALUES (r, 'counterparty_iban', 'DE02120300000000202051', 'user');
    v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r,
                 'due_date', (ps - interval '1 month' + interval '24 days')::date, 'amount', 3700));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP Vormonat 3700: %', v_res; END IF;
    v_prep := finance.fn_statement_prepare(v_stmt || jsonb_build_object('account_name', '__t_spx_giro3__',
                  'opening_balance', 4200, 'closing_balance', 7900, 'lines', jsonb_build_array(
                      jsonb_build_object('date', (ps + 24)::text, 'amount', 3700, 'counterparty', 'Arbeitgeber Muster',
                                         'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege'))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'matched') m
                      WHERE (m->>'recurring_payment_id')::int = r AND m->>'stage' = 'C')
       OR jsonb_array_length(v_prep->'plan_adjustments') <> 0 THEN
        RAISE EXCEPTION 'FAIL [SX4 Stufe C loest keine Plan-Anpassung aus]: %', v_prep;
    END IF;
    RAISE NOTICE 'PASS [SX4 Stufe C ohne Plan-Anpassung]';
END $$;
ROLLBACK;

-- Beitrag einer Versicherung bzw. Vorsorge aendert sich: beim 2. gleichen Ist-Betrag wird die besessene Kette wie ein
-- einfacher Dauerauftrag angepasst (der Beitrag steht nur an der Kette; der Split haengt den Besitzer um). Sonst rechnete
-- die Monatsrechnung dauerhaft mit dem alten Beitrag.
BEGIN;
DO $$
DECLARE
    ps DATE := date_trunc('month', CURRENT_DATE - 120)::date;
    pe DATE := (date_trunc('month', CURRENT_DATE - 120) + interval '1 month - 1 day')::date;
    a INT; r_ins INT; r_pen INT; v_ins INT; v_pen INT; v_res JSONB; v_stmt JSONB; v_prep JSONB; v_app JSONB;
BEGIN
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_spo_giro__', 'account_type', 'cash', 'currency', 'EUR',
             'opening_balance', 1000, 'opening_balance_date', (ps - 40)::text))->>'account_id')::int;
    v_res := finance.fn_create_insurance(jsonb_build_object('name', '__t_spo Hausrat__', 'insurance_company', 'Beispiel AG',
                 'premium_amount', 20, 'schedule_unit', 'month', 'schedule_day_of_month', 5,
                 'first_payment_date', (ps - interval '2 months' + interval '4 days')::date::text, 'debit_account_id', a));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP insurance: %', v_res; END IF;
    SELECT id, recurring_payment_id INTO v_ins, r_ins FROM finance.insurances WHERE name = '__t_spo Hausrat__';
    v_res := finance.fn_create_pension(jsonb_build_object('name', '__t_spo Rente__', 'pension_type', 'private',
                 'contribution_amount', 100, 'schedule_interval', 1, 'schedule_unit', 'month', 'schedule_day_of_month', 15,
                 'debit_account_id', a, 'first_payment_date', (ps - interval '2 months' + interval '14 days')::date::text));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP pension: %', v_res; END IF;
    v_pen := (v_res->>'pension_id')::int; r_pen := (v_res->>'recurring_payment_id')::int;
    -- Vormonat schon mit neuem Beitrag gebucht
    v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_ins,
                 'due_date', (ps - interval '1 month' + interval '4 days')::date, 'amount', 23));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP Vormonat Versicherung: %', v_res; END IF;
    v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_pen,
                 'due_date', (ps - interval '1 month' + interval '14 days')::date, 'amount', 110));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP Vormonat Vorsorge: %', v_res; END IF;
    -- Vor-Monat 2 (aelter als der Vormonat) ist nicht im Auszug: als erledigt markieren, sonst stuende er unter fehlt
    INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date)
    VALUES (r_ins, (ps - interval '2 months' + interval '4 days')::date), (r_pen, (ps - interval '2 months' + interval '14 days')::date);
    INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
    VALUES (r_ins, 'sepa_mandate', 'DE00ZZZ00000000003|SPO-INS', 'user'), (r_pen, 'sepa_mandate', 'DE00ZZZ00000000004|SPO-PEN', 'user');

    v_stmt := jsonb_build_object('account_name', '__t_spo_giro__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 1000 - 23 - 110, 'closing_balance', 1000 - 23 - 110 - 23 - 110, 'lines', jsonb_build_array(
            jsonb_build_object('date', (ps + 4)::text, 'amount', -23, 'counterparty', 'Beispiel AG', 'creditor_id', 'DE00ZZZ00000000003', 'mandate_ref', 'SPO-INS', 'purpose', 'Hausrat Beitrag'),
            jsonb_build_object('date', (ps + 14)::text, 'amount', -110, 'counterparty', 'Vorsorgekasse', 'creditor_id', 'DE00ZZZ00000000004', 'mandate_ref', 'SPO-PEN', 'purpose', 'Rente Beitrag')));
    v_prep := finance.fn_statement_prepare(v_stmt);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'matched') <> 2 THEN
        RAISE EXCEPTION 'SETUP Treffer erwartet: %', v_prep;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'plan_adjustments') x WHERE (x->>'head')::int = r_ins)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'plan_adjustments') x WHERE (x->>'head')::int = r_pen) THEN
        RAISE EXCEPTION 'FAIL [SO1 Versicherung und Vorsorge: Plan-Anpassung beim 2. gleichen Beitrag]: %', v_prep->'plan_adjustments';
    END IF;
    v_app := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_app->'plan_adjusted') <> 2 THEN
        RAISE EXCEPTION 'FAIL [SO2 apply passt beide Ketten an]: %', v_app;
    END IF;
    -- Besitzer zeigen auf den neuen Kopf, die Monatsrechnung kennt den neuen Beitrag
    IF (SELECT r.amount FROM finance.insurances i JOIN finance.recurring_payments r ON r.id = i.recurring_payment_id WHERE i.id = v_ins) IS DISTINCT FROM -23
       OR (SELECT r.amount FROM finance.pension p JOIN finance.recurring_payments r ON r.id = p.recurring_payment_id WHERE p.id = v_pen) IS DISTINCT FROM -110 THEN
        RAISE EXCEPTION 'FAIL [SO3 Besitzer zeigen auf die Kette mit neuem Beitrag]';
    END IF;
    RAISE NOTICE 'PASS [SO1-SO3 Beitrag von Versicherung und Vorsorge wird angepasst]';

    -- Schon geplante kuenftige Beitragsaenderung (Nachfolger-Glied): keine zweite Anpassung am alten Glied, apply bucht
    a := (finance.fn_create_account(jsonb_build_object('name', '__t_spo_giro2__', 'account_type', 'cash', 'currency', 'EUR',
             'opening_balance', 1000, 'opening_balance_date', (ps - 40)::text))->>'account_id')::int;
    v_res := finance.fn_create_insurance(jsonb_build_object('name', '__t_spo Glas__', 'insurance_company', 'Beispiel AG',
                 'premium_amount', 20, 'schedule_unit', 'month', 'schedule_day_of_month', 5,
                 'first_payment_date', (ps - interval '2 months' + interval '4 days')::date::text, 'debit_account_id', a));
    SELECT id, recurring_payment_id INTO v_ins, r_ins FROM finance.insurances WHERE name = '__t_spo Glas__';
    INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
    VALUES (r_ins, 'sepa_mandate', 'DE00ZZZ00000000005|SPO-GLAS', 'user');
    v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_ins,
                 'due_date', (ps - interval '1 month' + interval '4 days')::date, 'amount', 23));
    INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date) VALUES (r_ins, (ps - interval '2 months' + interval '4 days')::date);
    v_res := finance.fn_split_recurring_payment(r_ins, pe + 60, -25, NULL, NULL, NULL, NULL, NULL, NULL);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP kuenftige Aenderung: %', v_res; END IF;
    v_stmt := jsonb_build_object('account_name', '__t_spo_giro2__', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
        'opening_balance', 977, 'closing_balance', 954, 'lines', jsonb_build_array(
            jsonb_build_object('date', (ps + 4)::text, 'amount', -23, 'counterparty', 'Beispiel AG',
                               'creditor_id', 'DE00ZZZ00000000005', 'mandate_ref', 'SPO-GLAS', 'purpose', 'Glas Beitrag')));
    v_prep := finance.fn_statement_prepare(v_stmt);
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'matched') <> 1
       OR jsonb_array_length(v_prep->'plan_adjustments') <> 0 THEN
        RAISE EXCEPTION 'FAIL [SO4 geplante Aenderung: keine Anpassung am alten Glied]: %', v_prep;
    END IF;
    v_app := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [SO5 apply mit geplanter Aenderung]: %', v_app; END IF;
    RAISE NOTICE 'PASS [SO4-SO5 geplante kuenftige Aenderung bleibt, Auszug bucht]';
END $$;
ROLLBACK;
