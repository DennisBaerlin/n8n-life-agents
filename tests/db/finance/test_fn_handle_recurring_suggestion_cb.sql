-- ============================================================
-- test_fn_handle_recurring_suggestion_cb -- Knopf rsug:ok|no:<id>:<version> (erfundene Werte)
--   H1 Owner uebernimmt -> Dauerauftrag mit gespeicherten Werten, Zeile committed + id, gekuerzt, Text aus der angelegten
--   Zeile; H2 Doppeltipp -> schon uebernommen, kein zweiter; H3 Mitglied eigener Chat -> angelegt + owner_notice;
--   H4 Mitglied fremder Chat / Kind / Gruppenchat -> not_allowed, nichts; H5 abgelaufen -> keep_text; H6 alte Fassung ->
--   ueberholt; H7 nein -> declined; H8 Anlege-fn lehnt ab -> declined + Text; H9 inzwischen bekannt -> declined;
--   H10 Unsinn in data -> nie RAISE; H11 Uebertrag zwischen eigenen Konten (executed_by bank, kein Bank-Punkt);
--   H12 abgelaufener Stapel; H13/H14 Cashflow-Hinweis unter dem ✓-Text, nur einmal (Latch), beim Mitglied auch im
--   owner_notice (H3); H15 Spar-Deckungs-Zeile.
-- ============================================================
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'rh', NULL, 'lazy', 'x', jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','__rh_o__','first_name','Olli','last_name','Muster','role','owner','birth_date','1980-01-01','telegram_user_id',7601,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__rh_p__','first_name','Petra','last_name','Muster','role','partner','birth_date','1982-01-01','telegram_user_id',7602,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__rh_k__','first_name','Kim','last_name','Muster','role','child','birth_date','2012-01-01','telegram_user_id',7603,'as_of','2026-10-23')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

-- Texte (die Test-DB seedet den Katalog nicht): nur die Platzhalter, deren Werte der Test prueft
INSERT INTO core.ui_texts (key, lang, text, package)
SELECT v.k, x.l, v.t, 'finance' FROM (VALUES
    ('finance.recurring_suggest.msg_accepted', 'ok {name} {amount} {rhythm} {date} {account}'),
    ('finance.recurring_suggest.msg_declined', 'no {name}'),
    ('finance.recurring_suggest.msg_failed', 'fail {name} {reason}'),
    ('finance.recurring_suggest.owner_notice', '{member}: {name} {amount}'),
    ('finance.recurring_suggest.note_cashflow', 'cf {deficit}'),
    ('finance.note.funding_ok', 'sf {account} {in}'),
    ('finance.note.funding_ok_drain', 'sf {account} {drain}')) v(k, t)
CROSS JOIN (VALUES ('de'), ('en')) x(l)
ON CONFLICT DO NOTHING;

CREATE FUNCTION pg_temp.row(p_chat text, p_acct int, p_name text, p_amt numeric, p_extra jsonb DEFAULT '{}'::jsonb)
RETURNS int LANGUAGE sql AS $$
    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, status, source, origin, chat_id, version, merged_at)
    VALUES (gen_random_uuid(), 1, CASE WHEN p_extra ? 'from_account_id' THEN 'recurring_transfer' ELSE 'recurring_payment' END,
            jsonb_build_object('name', p_name, 'series', p_name, 'account_id', p_acct, 'account', '__t_rh_giro__', 'direction', 'expense',
               'amount', p_amt, 'schedule_unit', 'month', 'schedule_interval', 1, 'schedule_day_of_month', 3,
               'first_payment_date', (date_trunc('month', core.fn_today()) + interval '1 month 2 days')::date,
               'counterparty_iban', 'DE89370400440532013000', 'recurring_kind', 'rent', 'origin_kind', 'statement',
               'occurrences', jsonb_build_array(jsonb_build_object('date', (date_trunc('month', core.fn_today()) + interval '2 days')::date,
                                                                   'amount', -p_amt, 'account_id', p_acct))) || p_extra,
            'staged', 'vision', 'recurring_suggestion', p_chat, 1, now())
    RETURNING id;
$$;
CREATE FUNCTION pg_temp.cb(p_verb text, p_id int, p_ver int, p_chat text, p_type text DEFAULT 'private') RETURNS jsonb LANGUAGE sql AS $$
    SELECT finance.fn_handle_recurring_suggestion_cb(jsonb_build_object('data', 'rsug:' || p_verb || ':' || p_id || ':' || p_ver,
               'chat_id', p_chat, 'chat_type', p_type));
$$;

DO $$
DECLARE
    T      DATE := core.fn_today();
    v_acct INT; v_tg INT;
    v_a INT; v_b INT; v_c INT; v_d INT; v_e INT; v_f INT; v_g INT; v_sp INT; v_dep INT;
    v_r    JSONB;
    v_cnt  INT;
BEGIN
    DELETE FROM finance.import_staging;
    DELETE FROM core.notification_state WHERE source = 'finance' AND key = 'cashflow_coverage';
    v_acct := (finance.fn_create_account(jsonb_build_object('name', '__t_rh_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'opening_balance', 1000, 'opening_balance_date', (T - 200)::text))->>'account_id')::int;
    v_tg := (finance.fn_create_account(jsonb_build_object('name', '__t_rh_tg__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'account_number', 'DE02100100100006820101', 'opening_balance', 0, 'opening_balance_date', (T - 200)::text))->>'account_id')::int;
    v_a := pg_temp.row('7601', v_acct, 'Miete Test', 850);
    v_b := pg_temp.row('7602', v_acct, 'Kita Test', 200, '{"counterparty_iban":"DE02500105170137075030"}');
    v_c := pg_temp.row('7601', v_acct, 'Abo Test', 9.99, '{"counterparty_iban":"DE34200400000123456789"}');

    -- H4 Kind, Gruppenchat, Mitglied fremder Chat
    SELECT count(*) INTO v_cnt FROM finance.recurring_payments;
    IF pg_temp.cb('ok', v_a, 1, '7603')->>'reason' <> 'not_allowed' OR pg_temp.cb('ok', v_a, 1, '7601', 'group')->>'reason' <> 'not_allowed'
       OR pg_temp.cb('ok', v_a, 1, '7602')->>'reason' <> 'not_allowed' OR (SELECT count(*) FROM finance.recurring_payments) <> v_cnt
       OR (SELECT status FROM finance.import_staging WHERE id = v_a) <> 'staged' THEN
        RAISE EXCEPTION 'FAIL [H4 nicht erlaubt]';
    END IF;

    -- H1 Owner uebernimmt
    v_r := pg_temp.cb('ok', v_a, 1, '7601');
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r ? 'owner_notice' OR NULLIF(v_r->>'toast', '') IS NULL
       OR position('Miete Test' IN v_r->'edit'->>'text') = 0 OR position('850' IN v_r->'edit'->>'text') = 0 THEN
        RAISE EXCEPTION 'FAIL [H1 Rueckgabe]: %', v_r;
    END IF;
    -- H13 Event-Fold Cashflow: ohne Einnahme uebersteigt die Miete die Einnahmen -> Hinweis-Zeile mit dem Fehlbetrag
    -- unter dem ✓-Text (der Fold latcht; ohne die Zeile hiesse die Warnung "gesagt", obwohl niemand sie sah)
    IF split_part(v_r->'edit'->>'text', E'\n', 2) !~ '^cf .*850[.,]00'
       OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance' AND key = 'cashflow_coverage') THEN
        RAISE EXCEPTION 'FAIL [H13 Cashflow-Hinweis im ✓-Text]: %', v_r;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments r
                   WHERE r.id = (v_r->>'recurring_payment_id')::int AND r.name = 'Miete Test' AND r.amount = -850 AND r.account_id = v_acct
                     AND r.schedule_day_of_month = 3 AND r.first_payment_date = (date_trunc('month', T) + interval '1 month 2 days')::date)
       OR NOT EXISTS (SELECT 1 FROM finance.recurring_payment_keys k WHERE k.recurring_payment_id = (v_r->>'recurring_payment_id')::int
                      AND k.key_type = 'counterparty_iban' AND k.key_value = 'DE89370400440532013000') THEN
        RAISE EXCEPTION 'FAIL [H1 Dauerauftrag mit gespeicherten Werten + IBAN-Schluessel]';
    END IF;
    IF (SELECT status FROM finance.import_staging WHERE id = v_a) <> 'committed'
       OR (SELECT recurring_payment_id FROM finance.import_staging WHERE id = v_a) IS DISTINCT FROM (v_r->>'recurring_payment_id')::int
       OR (SELECT payload ? 'occurrences' OR payload ? 'counterparty_iban' FROM finance.import_staging WHERE id = v_a) THEN
        RAISE EXCEPTION 'FAIL [H1 Zeile committed + gekuerzt]';
    END IF;

    -- H2 Doppeltipp
    SELECT count(*) INTO v_cnt FROM finance.recurring_payments;
    v_r := pg_temp.cb('ok', v_a, 1, '7601');
    IF v_r->>'reason' <> 'already_committed' OR NOT (v_r->'edit'->>'keep_text')::boolean
       OR (SELECT count(*) FROM finance.recurring_payments) <> v_cnt THEN
        RAISE EXCEPTION 'FAIL [H2 Doppeltipp]: %', v_r;
    END IF;

    -- H3 Mitglied eigener Chat -> angelegt + Owner-Hinweis; die Haushalts-Warnung (Latch neu scharf) geht an beide
    DELETE FROM core.notification_state WHERE source = 'finance' AND key = 'cashflow_coverage';
    v_r := pg_temp.cb('ok', v_b, 1, '7602');
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR NULLIF(v_r->>'owner_notice', '') IS NULL
       OR position('Petra' IN v_r->>'owner_notice') = 0 OR position('Kita Test' IN v_r->>'owner_notice') = 0 THEN
        RAISE EXCEPTION 'FAIL [H3 Mitglied + owner_notice]: %', v_r;
    END IF;
    IF split_part(v_r->'edit'->>'text', E'\n', 2) !~ '^cf ' OR split_part(v_r->>'owner_notice', E'\n', 2) !~ '^cf ' THEN
        RAISE EXCEPTION 'FAIL [H3 Cashflow-Hinweis an Mitglied und Owner]: %', v_r;
    END IF;

    -- H6 alte Fassung
    UPDATE finance.import_staging SET version = 2 WHERE id = v_c;
    v_r := pg_temp.cb('ok', v_c, 1, '7601');
    IF v_r->>'reason' <> 'outdated' OR NOT (v_r->'edit'->>'keep_text')::boolean
       OR (SELECT status FROM finance.import_staging WHERE id = v_c) <> 'staged' THEN
        RAISE EXCEPTION 'FAIL [H6 ueberholt]: %', v_r;
    END IF;

    -- H7 nein
    v_r := pg_temp.cb('no', v_c, 2, '7601');
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (SELECT status FROM finance.import_staging WHERE id = v_c) <> 'declined'
       OR position('Abo Test' IN v_r->'edit'->>'text') = 0 THEN
        RAISE EXCEPTION 'FAIL [H7 nein]: %', v_r;
    END IF;
    IF pg_temp.cb('ok', v_c, 2, '7601')->>'reason' <> 'already_declined' THEN
        RAISE EXCEPTION 'FAIL [H7 danach schon abgelehnt]';
    END IF;

    -- H5 aufgeraeumt
    DELETE FROM finance.import_staging WHERE id = v_c;
    v_r := pg_temp.cb('ok', v_c, 2, '7601');
    IF v_r->>'reason' <> 'expired' OR NOT (v_r->'edit'->>'keep_text')::boolean THEN
        RAISE EXCEPTION 'FAIL [H5 abgelaufen]: %', v_r;
    END IF;

    -- H8 Anlege-fn lehnt ab (ungueltige IBAN im Payload)
    v_d := pg_temp.row('7601', v_acct, 'Kaputt Test', 12, '{"counterparty_iban":"DE00123"}');
    SELECT count(*) INTO v_cnt FROM finance.recurring_payments;
    v_r := pg_temp.cb('ok', v_d, 1, '7601');
    IF (v_r->>'ok')::boolean OR v_r->>'reason' <> 'create_rejected' OR (SELECT status FROM finance.import_staging WHERE id = v_d) <> 'declined'
       OR NULLIF(v_r->'edit'->>'text', '') IS NULL OR (SELECT count(*) FROM finance.recurring_payments) <> v_cnt THEN
        RAISE EXCEPTION 'FAIL [H8 Anlege-fn lehnt ab]: %', v_r;
    END IF;

    -- H9 inzwischen per IBAN bekannt (zweiter Vorschlag fuer die Miete)
    v_e := pg_temp.row('7601', v_acct, 'Wohnung Test', 850);
    v_r := pg_temp.cb('ok', v_e, 1, '7601');
    IF v_r->>'reason' <> 'already_known' OR (SELECT status FROM finance.import_staging WHERE id = v_e) <> 'declined' THEN
        RAISE EXCEPTION 'FAIL [H9 schon bekannt]: %', v_r;
    END IF;

    -- H10 Unsinn
    IF (finance.fn_handle_recurring_suggestion_cb('{"data":"rsug:ok:x","chat_id":"7601","chat_type":"private"}')->>'ok')::boolean
       OR (finance.fn_handle_recurring_suggestion_cb('{"data":"rsug:maybe:1:1","chat_id":"7601","chat_type":"private"}')->>'ok')::boolean
       OR (finance.fn_handle_recurring_suggestion_cb('{}')->>'ok')::boolean
       OR (finance.fn_handle_recurring_suggestion_cb('{"data":"rsug:ok:99999999999:1","chat_id":"7601","chat_type":"private"}')->>'ok')::boolean THEN
        RAISE EXCEPTION 'FAIL [H10 Unsinn]';
    END IF;

    -- H11 Uebertrag
    v_f := pg_temp.row('7601', v_acct, 'Sparen Test', 100, jsonb_build_object('from_account_id', v_acct, 'to_account_id', v_tg,
              'counterparty_iban', 'DE02100100100006820101', 'recurring_kind', 'own_transfer'));
    v_r := pg_temp.cb('ok', v_f, 1, '7601');
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments r
            WHERE r.id = (v_r->>'recurring_payment_id')::int AND r.account_id = v_acct AND r.target_account_id = v_tg AND r.amount = -100) THEN
        RAISE EXCEPTION 'FAIL [H11 Uebertrag]: %', v_r;
    END IF;
    -- H11b im Auszug gesehen = laeuft bei der Bank: kein offener Bank-Punkt "bei der Bank einrichten"
    IF (SELECT executed_by FROM finance.recurring_payments WHERE id = (v_r->>'recurring_payment_id')::int) IS DISTINCT FROM 'bank'
       OR EXISTS (SELECT 1 FROM finance.bank_todos b WHERE b.head_id = (v_r->>'recurring_payment_id')::int AND b.status = 'open')
       OR position('bank_setup' IN v_r->'edit'->>'text') > 0 THEN
        RAISE EXCEPTION 'FAIL [H11b Uebertrag ohne Bank-Punkt]: %', v_r;
    END IF;

    -- H15 Event-Fold Spar-Deckung: Einnahme auf ein Konto, das einen Sparplan bezahlt -> "Danach ..."-Zeile mit
    -- formatiertem Betrag; Kartenzeilen ohne Fold-Herkunft (IBAN-Schluessel "Falls falsch, abbrechen") fehlen
    v_sp := (finance.fn_create_account(jsonb_build_object('name', '__t_rh_sp__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'opening_balance', 1000, 'opening_balance_date', (T - 200)::text))->>'account_id')::int;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__t_rh_dep__', 'stocks_depot', 'EUR', 'active', v_sp) RETURNING id INTO v_dep;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('rh Plan', v_sp, -200, 'month', T + 2, T + 2) RETURNING id INTO v_cnt;
    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('rh Plan', v_dep, 'RHX', 'Welt ETF', v_cnt);
    v_g := pg_temp.row('7601', v_sp, 'Zuschuss Test', 500, '{"direction":"income","recurring_kind":"benefit","counterparty_iban":"DE75512108001245126199"}');
    v_r := pg_temp.cb('ok', v_g, 1, '7601');
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->'edit'->>'text' !~ E'\nsf __t_rh_sp__ \\S*500[.,]00'
       OR position('recurring_iban_key' IN v_r->'edit'->>'text') > 0 OR position('{' IN v_r->'edit'->>'text') > 0 THEN
        RAISE EXCEPTION 'FAIL [H15 Spar-Deckungs-Hinweis im ✓-Text]: %', v_r;
    END IF;
    -- H14 Lage bleibt negativ binnen 48 h (Latch) -> kein zweiter Cashflow-Hinweis
    IF v_r->'edit'->>'text' ~ E'\ncf ' THEN
        RAISE EXCEPTION 'FAIL [H14 Cashflow-Hinweis nur einmal]: %', v_r;
    END IF;
    -- H12 Stapel seit mehr als 7 Tagen nicht ergaenzt, aber nicht geloescht -> abgelaufen, nichts angelegt
    v_e := pg_temp.row('7601', v_acct, 'Alt Test', 44, '{"counterparty_iban":"DE02120300000000202051"}');
    UPDATE finance.import_staging SET merged_at = now() - interval '8 days' WHERE id = v_e;
    SELECT count(*) INTO v_cnt FROM finance.recurring_payments;
    v_r := pg_temp.cb('ok', v_e, 1, '7601');
    IF v_r->>'reason' <> 'expired' OR NOT (v_r->'edit'->>'keep_text')::boolean
       OR (SELECT count(*) FROM finance.recurring_payments) <> v_cnt
       OR (SELECT status FROM finance.import_staging WHERE id = v_e) <> 'staged' THEN
        RAISE EXCEPTION 'FAIL [H12 abgelaufener Stapel]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [H1-H15 fn_handle_recurring_suggestion_cb]';
END $$;
ROLLBACK;
