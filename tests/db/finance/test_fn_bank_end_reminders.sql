-- tests/db/finance/test_fn_bank_end_reminders.sql
-- Erinnerung "Auftrag bei der Bank beenden": fn_bank_end_due (wer ist faellig), fn_bank_end_claim (Nachrichten je
--   Empfaenger + Latch), fn_bank_stop_note_told (Beenden im Bot latcht den Owner). db_test hat KEIN seed_data ->
--   family + Registry self-seeden. Werte erfunden.
BEGIN;

CREATE FUNCTION pg_temp.mk(p_name text, p_acct int, p_tgt int, p_last date, p_by text DEFAULT NULL) RETURNS int
LANGUAGE sql AS $$
    INSERT INTO finance.recurring_payments
        (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, executed_by)
    VALUES (p_name, p_acct, p_tgt, -100, 'month', p_last, p_last, p_last + 1, p_by) RETURNING id;
$$;
CREATE FUNCTION pg_temp.due_row(p_id int, p_on date DEFAULT core.fn_today()) RETURNS jsonb LANGUAGE sql AS $$
    SELECT e FROM jsonb_array_elements(finance.fn_bank_end_due(p_on)) e WHERE (e->>'head')::int = p_id;
$$;
-- Empfaenger + Namen einer Claim-Antwort als "owner:a,b|<pid>:c" (Reihenfolge wie geliefert)
CREATE FUNCTION pg_temp.msgs(r jsonb) RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE(string_agg(m->>'recipient' || ':' ||
           (SELECT string_agg(i->>'name', ',' ORDER BY i->>'name') FROM jsonb_array_elements(m->'items') i), '|' ORDER BY o), '')
      FROM jsonb_array_elements(r) WITH ORDINALITY x(m, o);
$$;
CREATE FUNCTION pg_temp.latched(p_key text) RETURNS boolean LANGUAGE sql AS $$
    SELECT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance:bank_end' AND key = p_key AND state = 'fired');
$$;

DO $$
DECLARE
  v_today date := core.fn_today();
  v_l date := v_today - 3;
  v_cash int; v_tgt int; v_p2p int; v_nob int; v_depot int;
  v_a_owner int; v_a_partner int; v_a_unpaired int; v_a_child int;
  v_rp int; v_rp2 int; v_rp3 int; v_goal int;
  v_row jsonb; v_r jsonb; v_m text;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'bank_end fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__be_owner__','first_name','Olli','last_name','Muster','role','owner',
                               'birth_date','1980-01-01','telegram_user_id',7401,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__be_partner__','first_name','Petra','last_name','Muster','role','partner',
                               'birth_date','1982-01-01','telegram_user_id',7402,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__be_unpaired__','first_name','Uli','last_name','Muster','role','partner',
                               'birth_date','1983-01-01','as_of','2026-10-23'),
            jsonb_build_object('person_id','__be_child__','first_name','Kim','last_name','Muster','role','child',
                               'birth_date','2012-01-01','telegram_user_id',7404,'as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES
    ('remind_bank_end', 'finance', 'household', true), ('remind_bank_end_person', 'finance', 'person', true)
  ON CONFLICT (cron_key) DO UPDATE SET scope = excluded.scope, default_enabled = excluded.default_enabled;
  INSERT INTO core.config (package, category, key, value) VALUES
    ('finance', 'cron_enable', 'remind_bank_end', 'true'), ('finance', 'cron_enable', 'remind_bank_end_person', 'true')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true';

  INSERT INTO finance.accounts (name, account_type, currency, status, bank) VALUES ('__be_cash__','cash','EUR','active','Musterbank') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__be_tgt__','cash','EUR','active') RETURNING id INTO v_tgt;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__be_nob__','cash','EUR','active') RETURNING id INTO v_nob;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__be_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, bank)
    VALUES ('__be_depot__','stocks_depot','EUR','active', v_tgt, 'Testbroker') RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES
    ('__be_a_owner__','cash','EUR','active','Musterbank','__be_owner__') RETURNING id INTO v_a_owner;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES
    ('__be_a_partner__','cash','EUR','active','Musterbank','__be_partner__') RETURNING id INTO v_a_partner;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES
    ('__be_a_unpaired__','cash','EUR','active','Musterbank','__be_unpaired__') RETURNING id INTO v_a_unpaired;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES
    ('__be_a_child__','cash','EUR','active','Musterbank','__be_child__') RETURNING id INTO v_a_child;

  -- [1] Fenster: L + 3 bis L + 60
  v_rp := pg_temp.mk('__be_win__', v_cash, v_tgt, v_l, 'bank');
  v_row := pg_temp.due_row(v_rp);
  IF v_row IS NULL OR (v_row->>'last_due')::date IS DISTINCT FROM v_l OR v_row->>'kind' IS DISTINCT FROM 'standing_order' OR v_row->>'execution' IS DISTINCT FROM 'bank'
     OR v_row->>'name' IS DISTINCT FROM '__be_win__' OR (v_row->>'amount')::numeric IS DISTINCT FROM 100 OR v_row->>'currency' IS DISTINCT FROM 'EUR'
     OR v_row->>'bank' IS DISTINCT FROM 'Musterbank' OR v_row->>'to_name' IS DISTINCT FROM '__be_tgt__'
     OR v_row->>'to_label' IS DISTINCT FROM finance.fn_account_label(NULL, 'cash', '__be_tgt__') THEN
    RAISE EXCEPTION 'FAIL [1 L-3 faellig mit Feldern]: %', v_row; END IF;
  IF pg_temp.due_row(v_rp, v_today - 1) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1 L+2 zu frueh]'; END IF;
  IF pg_temp.due_row(v_rp, v_l + 60) IS NULL THEN RAISE EXCEPTION 'FAIL [1 L+60 noch faellig]'; END IF;
  IF pg_temp.due_row(v_rp, v_l + 61) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1 L+61 zu spaet]'; END IF;
  RAISE NOTICE 'PASS [1] Fenster L+3..L+60';

  -- [2] Wer ausfuehrt: manual nie, unknown mit "falls", P2P-Quelle ohne Angabe nie
  v_rp := pg_temp.mk('__be_man__', v_cash, v_tgt, v_l, 'manual');
  IF pg_temp.due_row(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 manual]'; END IF;
  v_rp := pg_temp.mk('__be_unk__', v_nob, v_tgt, v_l);
  v_row := pg_temp.due_row(v_rp);
  IF v_row->>'execution' IS DISTINCT FROM 'unknown' OR v_row->>'bank' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 unknown]: %', v_row; END IF;
  v_rp := pg_temp.mk('__be_p2p_so__', v_p2p, v_tgt, v_l);
  IF pg_temp.due_row(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 P2P]'; END IF;
  RAISE NOTICE 'PASS [2] manual/unknown/P2P';

  -- [3] Sparplan: Institut + Inhaber kommen vom Depot, Name vom Sparplan
  v_rp := pg_temp.mk('__be_plan_rp__', v_cash, NULL, v_l);
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__be_plan__', v_depot, 'TST', 'Test ETF', v_rp);
  v_row := pg_temp.due_row(v_rp);
  IF v_row->>'kind' IS DISTINCT FROM 'savings_plan' OR v_row->>'execution' IS DISTINCT FROM 'bank' OR v_row->>'bank' IS DISTINCT FROM 'Testbroker'
     OR v_row->>'name' IS DISTINCT FROM '__be_plan__' OR v_row->>'to_name' IS DISTINCT FROM '__be_depot__'
     OR v_row->>'to_label' IS DISTINCT FROM finance.fn_account_label(NULL, 'stocks_depot', '__be_depot__') THEN
    RAISE EXCEPTION 'FAIL [3 Sparplan]: %', v_row; END IF;
  RAISE NOTICE 'PASS [3] Sparplan';

  -- [4] Lastschrift ohne Ziel-Konto: nie
  v_rp := pg_temp.mk('__be_debit__', v_cash, NULL, v_l);
  IF pg_temp.due_row(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4 Lastschrift]'; END IF;
  RAISE NOTICE 'PASS [4] Lastschrift';

  -- [5] offen; kuenftiger Split (Kopf offen, Vorgaenger ist keine eigene Kette); Ende ohne Termin davor (L NULL)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, executed_by)
    VALUES ('__be_open__', v_cash, v_tgt, -100, 'month', v_today - 90, v_today - 90, 'bank') RETURNING id INTO v_rp;
  IF pg_temp.due_row(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 offen]'; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, executed_by)
    VALUES ('__be_split_a__', v_cash, v_tgt, -100, 'month', v_today - 90, v_today - 90, v_today - 10, 'bank') RETURNING id INTO v_rp;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, executed_by, predecessor_id)
    VALUES ('__be_split_b__', v_cash, v_tgt, -120, 'month', v_today - 90, v_today - 10, 'bank', v_rp) RETURNING id INTO v_rp2;
  IF pg_temp.due_row(v_rp) IS NOT NULL OR pg_temp.due_row(v_rp2) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 Split]'; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, executed_by)
    VALUES ('__be_noocc__', v_cash, v_tgt, -100, 'month', v_today - 40, v_today - 30, v_today - 20, 'bank') RETURNING id INTO v_rp;
  IF finance.fn_recurring_last_due(v_rp) IS NOT NULL OR pg_temp.due_row(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 L NULL]'; END IF;
  RAISE NOTICE 'PASS [5] offen/Split/kein Termin';

  -- [9] Pausierte Kette nie; geschlossener Sparplan nie (fn_close_savings_plan pausiert die Kette)
  v_rp := pg_temp.mk('__be_paused__', v_cash, v_tgt, v_l, 'bank');
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_rp;
  IF pg_temp.due_row(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [9 pausiert]'; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__be_close_rp__', v_cash, -50, 'month', v_today - 40, v_today - 40) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__be_close__', v_depot, 'TS2', 'Test ETF 2', v_rp);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
    VALUES (v_cash, -50, v_today - 40, 'other', v_rp, '__be_close_tx__');
  v_r := finance.fn_close_savings_plan('{"savings_plan_name":"__be_close__"}');
  IF v_r->>'action' <> 'closed' OR pg_temp.due_row(v_rp, v_today + 5) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [9 geschlossener Sparplan]: % %', v_r, pg_temp.due_row(v_rp, v_today + 5); END IF;
  RAISE NOTICE 'PASS [9] pausiert/geschlossen';

  -- [11] Sparziel-Rate nennt das Ziel
  v_rp := pg_temp.mk('__be_goal_rp__', v_cash, v_tgt, v_l, 'bank');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id)
    VALUES ('__be_goal__', 1000, v_today + 300, v_rp) RETURNING id INTO v_goal;
  v_row := pg_temp.due_row(v_rp);
  IF v_row->>'goal' IS DISTINCT FROM '__be_goal__' THEN RAISE EXCEPTION 'FAIL [11 goal]: %', v_row; END IF;
  RAISE NOTICE 'PASS [11] Sparziel';

  -- [13] Leer gekuerzter Kopf [x,x): kein Termin, keine Erinnerung (der Kuerzende sah die Karte)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, executed_by)
    VALUES ('__be_empty__', v_cash, v_tgt, -100, 'month', v_today - 10, v_today - 10, v_today - 10, 'bank') RETURNING id INTO v_rp;
  IF pg_temp.due_row(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [13 leerer Kopf]'; END IF;
  RAISE NOTICE 'PASS [13] leerer Kopf';

  -- Alles Bisherige raeumen: ab hier zaehlen die Empfaenger-Faelle exakt
  DELETE FROM finance.savings_goals WHERE id = v_goal;
  DELETE FROM finance.savings_plans;
  UPDATE finance.recurring_payments SET predecessor_id = NULL;
  DELETE FROM finance.transactions WHERE description = '__be_close_tx__';
  DELETE FROM finance.recurring_payments;

  -- [14/15/16/16a/17] Empfaenger: Partner gekoppelt -> beide; Owner -> eine; nicht gekoppelt, Kind, Gemeinschaft -> nur Owner
  PERFORM pg_temp.mk('p', v_a_partner, v_tgt, v_l, 'bank');
  PERFORM pg_temp.mk('o', v_a_owner, v_tgt, v_l, 'bank');
  v_rp3 := pg_temp.mk('u', v_a_unpaired, v_tgt, v_l, 'bank');
  PERFORM pg_temp.mk('k', v_a_child, v_tgt, v_l, 'bank');
  PERFORM pg_temp.mk('g', v_cash, v_tgt, v_l, 'bank');
  v_r := finance.fn_bank_end_claim(v_today);
  v_m := pg_temp.msgs(v_r);
  IF v_m <> 'owner:g,k,o,p,u|__be_partner__:p' THEN RAISE EXCEPTION 'FAIL [14-17 Empfaenger]: %', v_m; END IF;
  IF v_r->0->>'chat_id' IS NOT NULL OR (v_r->1->>'chat_id')::bigint <> 7402 THEN RAISE EXCEPTION 'FAIL [14 chat_id]: %', v_r; END IF;
  IF (SELECT i->>'holder_name' FROM jsonb_array_elements(v_r->0->'items') i WHERE i->>'name' = 'p') IS DISTINCT FROM 'Petra' THEN
    RAISE EXCEPTION 'FAIL [14 Name beim Owner]: %', v_r->0; END IF;
  IF (SELECT i->>'holder_name' FROM jsonb_array_elements(v_r->0->'items') i WHERE i->>'name' = 'o') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [15 eigener Name ohne Klammer]: %', v_r->0; END IF;
  RAISE NOTICE 'PASS [14-17] Empfaenger';

  -- [6/20] Zweiter Claim am selben Tag: nichts
  IF finance.fn_bank_end_claim(v_today) <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [6 Einmaligkeit]'; END IF;
  RAISE NOTICE 'PASS [6/20] Einmaligkeit';

  -- [16 Fortsetzung] Kopplung im Fenster: der Partner bekommt die Erinnerung noch (Owner nicht erneut)
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,2,telegram_user_id}', '7403') WHERE name = 'family';
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(v_today));
  IF v_m <> '__be_unpaired__:u' THEN RAISE EXCEPTION 'FAIL [16 nachtraeglich gekoppelt]: %', v_m; END IF;
  RAISE NOTICE 'PASS [16] nachtraeglich gekoppelt';

  -- [7] Verlaengern: neues L -> erneut faellig
  UPDATE finance.recurring_payments SET valid_to = v_l + 32, schedule_day_of_month = NULL WHERE id = v_rp3;
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(v_today + 40));
  IF v_m NOT LIKE '%u%' OR v_m NOT LIKE 'owner:%' THEN RAISE EXCEPTION 'FAIL [7 Verlaengern]: %', v_m; END IF;
  RAISE NOTICE 'PASS [7] Verlaengern';

  -- [18/19/E7] Abschalten: Person aus -> nur Owner, Person-Key frei; Haushalt aus -> nur Person, nichts gelatcht
  DELETE FROM finance.recurring_payments;
  v_rp := pg_temp.mk('p2', v_a_partner, v_tgt, v_l, 'bank');
  INSERT INTO agent.reminder_prefs (person_id, cron_key, enabled) VALUES ('__be_partner__', 'remind_bank_end_person', false);
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(v_today));
  IF v_m <> 'owner:p2' OR pg_temp.latched(v_rp || ':' || v_l || ':__be_partner__') THEN RAISE EXCEPTION 'FAIL [18 Person aus]: %', v_m; END IF;
  DELETE FROM agent.reminder_prefs WHERE person_id = '__be_partner__';
  DELETE FROM finance.recurring_payments;
  v_rp := pg_temp.mk('p3', v_a_partner, v_tgt, v_l, 'bank');
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'remind_bank_end';
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(v_today));
  IF v_m <> '__be_partner__:p3' OR pg_temp.latched(v_rp || ':' || v_l || ':owner') THEN RAISE EXCEPTION 'FAIL [19 Haushalt aus]: %', v_m; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'remind_bank_end';
  RAISE NOTICE 'PASS [18/19] Abschalten';

  -- [8/21] Beenden im Bot, L <= heute: Probelauf latcht nicht, echter Write latcht NUR den Owner-Key
  DELETE FROM finance.recurring_payments;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, executed_by)
    VALUES ('stop', v_a_partner, v_tgt, -100, 'month', v_today - 33, v_today - 33, 'bank') RETURNING id INTO v_rp;
  v_r := core.fn_dry_run('finance.fn_set_recurring_payment(jsonb)'::regprocedure,
           jsonb_build_object('recurring_payment_id', v_rp, 'valid_to', (v_today - 1)::text));
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance:bank_end' AND key LIKE v_rp || ':%') THEN
    RAISE EXCEPTION 'FAIL [8 Probelauf latcht]: %', v_r; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'valid_to', (v_today - 1)::text));
  IF NOT pg_temp.latched(v_rp || ':' || finance.fn_recurring_last_due(v_rp) || ':owner')
     OR pg_temp.latched(v_rp || ':' || finance.fn_recurring_last_due(v_rp) || ':__be_partner__') THEN
    RAISE EXCEPTION 'FAIL [21 nur Owner-Key]: %', v_r; END IF;
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(finance.fn_recurring_last_due(v_rp) + 3));
  IF v_m <> '__be_partner__:stop' THEN RAISE EXCEPTION 'FAIL [21 Owner still, Inhaber bekommt]: %', v_m; END IF;
  RAISE NOTICE 'PASS [8/21] Beenden im Bot';

  -- [21a] GC: nur Merker, die vor mehr als 400 Tagen gesetzt wurden
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES
    ('finance:bank_end', '1:2024-01-01:owner', 'fired', v_today - 401),
    ('finance:bank_end', '2:2026-01-01:owner', 'fired', v_today - 399),
    ('finance', 'fremd:alt', 'fired', v_today - 500)
  ON CONFLICT DO NOTHING;
  PERFORM finance.fn_bank_end_claim(v_today);
  IF pg_temp.latched('1:2024-01-01:owner') OR NOT pg_temp.latched('2:2026-01-01:owner')
     OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance' AND key = 'fremd:alt') THEN
    RAISE EXCEPTION 'FAIL [21a GC]'; END IF;
  RAISE NOTICE 'PASS [21a] GC';

  -- [Budget] kein Platz -> nichts gemerkt, Folgetag gemeldet; Owner und Partner je eigenes Budget
  DELETE FROM finance.recurring_payments;
  DELETE FROM core.notification_state WHERE source = 'finance:bank_end';
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  v_rp := pg_temp.mk('bu', v_a_partner, v_tgt, v_l, 'bank');
  PERFORM core.fn_proactive_claim(NULL, 'x1', 'normal'); PERFORM core.fn_proactive_claim(NULL, 'x2', 'normal');
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(v_today));
  IF v_m <> '__be_partner__:bu' OR pg_temp.latched(v_rp || ':' || v_l || ':owner') THEN RAISE EXCEPTION 'FAIL [Budget voll]: %', v_m; END IF;
  UPDATE core.proactive_budget SET day = day - 1;
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(v_today));
  IF v_m <> 'owner:bu' OR NOT pg_temp.latched(v_rp || ':' || v_l || ':owner') THEN RAISE EXCEPTION 'FAIL [Budget Folgetag]: %', v_m; END IF;
  -- gemeldet -> kein Slot
  DELETE FROM core.proactive_budget;
  v_m := pg_temp.msgs(finance.fn_bank_end_claim(v_today));
  IF v_m <> '' OR EXISTS (SELECT 1 FROM core.proactive_budget) THEN RAISE EXCEPTION 'FAIL [Budget told]: %', v_m; END IF;
  RAISE NOTICE 'PASS [Budget]';

  -- [Rollen] Der Cron laeuft unter finance_rw, die Lese-fn auch unter finance_ro (Details test_role_permissions)
  SET LOCAL ROLE finance_rw;
  PERFORM finance.fn_bank_end_claim(v_today);
  RESET ROLE;

  -- [10] Reset raeumt beide Latch-Quellen
  PERFORM finance.fn_price_gap_claim('feed_down');
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance:prices' AND key = 'feed_down') THEN
    RAISE EXCEPTION 'FAIL [10 Quelle finance:prices]'; END IF;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status = 'active';
  PERFORM core.fn_reset_user_data('RESET');
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source IN ('finance:bank_end', 'finance:prices')) THEN
    RAISE EXCEPTION 'FAIL [10 Reset]'; END IF;
  RAISE NOTICE 'PASS [10] Reset';
END $$;
ROLLBACK;
