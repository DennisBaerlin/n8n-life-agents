-- tests/db/finance/test_fn_transfer_free_end.sql
-- Umschichtung mit Enddatum: until_free_money an fn_create_recurring_transfer / fn_set_recurring_payment
-- setzt das Ende ueber fn_transfer_free_end (letzter Termin, bevor Ziel-Geld der Quelle angefasst wird; Rechnung =
-- fn_account_funding mit der Zahlung). Dazu fn_recurring_last_due und die Felder drawdown / inflow_ends von
-- fn_account_funding. Werte erfunden.
--   (1) create until_free_money: P2P 20000, Ziel-Geld 8000, 5000/Monat -> zwei Termine, Ende nach dem zweiten
--   (2) Quelle: drawdown {last_date, monthly 5000, target, to_plan}, state ok, kein runs_out_on
--   (3) Ziel-Verrechnungskonto mit Sparplan: inflow_ends = letzter Termin (danach reicht es nicht)
--   (4) set until_free_money auf einen bestehenden offenen Uebertrag: dasselbe Ende
--   (5) no_free_money (kein freies Geld) -> {ok:false}, kein Insert
--   (6) funding_unknown (Alltag unbekannt) -> {ok:false}; free_money_beyond_horizon (kleine Rate)
--   (7) until_free_money + valid_to -> {ok:false}; set mit amount -> {ok:false}
--   (8) fn_recurring_last_due: offene Kette NULL; kuenftige Betragsaenderung ist kein Ende
--   (9) beendet/pausiert -> not_running; (10) source_short; (11) Halbierung; (12) Ampel neutral ohne drawdown
BEGIN;
DO $$
DECLARE
  m1 DATE := (date_trunc('month', current_date) + interval '1 month' + interval '24 days')::date;
  m2 DATE := (date_trunc('month', current_date) + interval '2 months' + interval '24 days')::date;
  v_giro INT; v_p2p INT; v_settle INT; v_depot INT; v_p2p2 INT; v_p2p3 INT; v_spend INT; v_goal INT; v_goal2 INT; v_short INT; v_bis INT; v_rp INT; v_rp2 INT;
  v_res JSONB; v_f JSONB; v_cnt INT;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_giro__','cash','EUR','active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_settle__','cash','EUR','active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__tfe_depot__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_p2p2__','p2p','EUR','active') RETURNING id INTO v_p2p2;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_spend__','cash','EUR','active') RETURNING id INTO v_spend;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_p2p3__','p2p','EUR','active') RETURNING id INTO v_p2p3;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_p2p, 20000, current_date - 5, 'other'), (v_p2p2, 20000, current_date - 5, 'other'), (v_spend, 20000, current_date - 5, 'other'), (v_p2p3, 20000, current_date - 5, 'other');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__tfe goal__', 8000, (current_date + interval '1 year')::date, 'active') RETURNING id INTO v_goal;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_p2p, 'amount', 8000));
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name','__tfe_plan__','depot_name','__tfe_depot__','isin','IE00B4L5Y983',
            'symbol','IUSQ','security_name','iShares MSCI World','amount',1000,'schedule_interval',1,'schedule_unit','month',
            'schedule_day_of_month', 1, 'first_payment_date', (date_trunc('month', current_date) + interval '2 months')::date::text));

  -- (1) create until_free_money
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__tfe Umzug__', 'from_account_id', v_p2p, 'to_account_id', v_settle, 'amount', 5000,
    'schedule_unit', 'month', 'schedule_day_of_month', 25, 'first_payment_date', m1::text, 'until_free_money', true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1 ok]: %', v_res; END IF;
  v_rp := (v_res->>'recurring_payment_id')::int;
  IF (v_res->'effective'->>'last_execution')::date IS DISTINCT FROM m2 THEN RAISE EXCEPTION 'FAIL [1 last_execution]: erwartet %, got %', m2, v_res; END IF;
  IF (v_res->'effective'->>'free_after')::numeric IS DISTINCT FROM 2000 THEN RAISE EXCEPTION 'FAIL [1 free_after]: %', v_res; END IF;
  IF (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM m2 + 1 THEN RAISE EXCEPTION 'FAIL [1 valid_to]'; END IF;
  IF finance.fn_recurring_last_due(v_rp) IS DISTINCT FROM m2 THEN RAISE EXCEPTION 'FAIL [1 last_due]'; END IF;
  RAISE NOTICE 'PASS [1 create until_free_money -> Ende nach dem 2. Termin, frei danach 2000]';

  -- (2) drawdown an der Quelle
  v_f := finance.fn_account_funding(v_p2p);
  IF v_f->>'state' IS DISTINCT FROM 'ok' OR v_f->>'runs_out_on' IS NOT NULL
     OR (v_f->'drawdown'->>'last_date')::date IS DISTINCT FROM m2 OR (v_f->'drawdown'->>'monthly')::numeric IS DISTINCT FROM 5000
     OR (v_f->'drawdown'->>'target_account_id')::int IS DISTINCT FROM v_settle OR (v_f->'drawdown'->>'to_plan')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [2 drawdown]: %', v_f; END IF;
  RAISE NOTICE 'PASS [2 Quelle: drawdown, state ok]';

  -- (3) inflow_ends am Verrechnungskonto: 2 x 5000 rein, 1000/Monat raus -> reicht nicht bis zum Horizont
  v_f := finance.fn_account_funding(v_settle);
  IF (v_f->>'inflow_ends')::date IS DISTINCT FROM m2 OR v_f->>'runs_out_on' IS NULL OR v_f ? 'drawdown' AND v_f->'drawdown' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3 inflow_ends]: %', v_f; END IF;
  RAISE NOTICE 'PASS [3 Ziel-Konto: inflow_ends = letzter Zufluss]';

  -- (4) set until_free_money auf einen offenen Uebertrag (zweite P2P-Quelle, kein Ziel-Geld -> 20000 frei = 4 Termine)
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__tfe offen__', 'from_account_id', v_p2p2, 'to_account_id', v_giro, 'amount', 5000,
    'schedule_unit', 'month', 'schedule_day_of_month', 25, 'first_payment_date', m1::text)) INTO v_res;
  v_rp2 := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp2, 'until_free_money', true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->'effective'->>'last_execution')::date IS DISTINCT FROM (m1 + interval '3 months')::date THEN
    RAISE EXCEPTION 'FAIL [4 set]: %', v_res; END IF;
  RAISE NOTICE 'PASS [4 set until_free_money -> Ende nach dem 4. Termin]';

  -- (5) kein freies Geld: P2P hat nach (1) noch 2000 frei, ein zweiter Uebertrag 5000 ab m1 fasst sofort Ziel-Geld an
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__tfe zu viel__', 'from_account_id', v_p2p, 'to_account_id', v_giro, 'amount', 5000,
    'schedule_unit', 'month', 'schedule_day_of_month', 20, 'first_payment_date', m1::text, 'until_free_money', true)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'no_free_money' THEN RAISE EXCEPTION 'FAIL [5 no_free_money]: %', v_res; END IF;
  SELECT count(*) INTO v_cnt FROM finance.recurring_payments WHERE name = '__tfe zu viel__';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [5 kein Insert]: % Zeilen', v_cnt; END IF;
  RAISE NOTICE 'PASS [5 no_free_money, Savepoint rollt den Insert zurueck]';

  -- (6) funding_unknown: Quelle mit Alltagsabgang ohne Auszug; beyond_horizon: 10 EUR/Monat bei 20000 frei
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__tfe Miete__', v_spend, -500, 'month', m1, m1);
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__tfe unbekannt__', 'from_account_id', v_spend, 'to_account_id', v_giro, 'amount', 1000,
    'schedule_unit', 'month', 'first_payment_date', m1::text, 'until_free_money', true)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'funding_unknown' THEN RAISE EXCEPTION 'FAIL [6 funding_unknown]: %', v_res; END IF;
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__tfe langsam__', 'from_account_id', v_p2p3, 'to_account_id', v_settle, 'amount', 10,
    'schedule_unit', 'month', 'first_payment_date', (m2 + interval '6 months')::date::text, 'until_free_money', true)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'free_money_beyond_horizon' THEN RAISE EXCEPTION 'FAIL [6 beyond_horizon]: %', v_res; END IF;
  RAISE NOTICE 'PASS [6 funding_unknown, free_money_beyond_horizon]';

  -- (7) Kombinationen
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__tfe kombi__', 'from_account_id', v_p2p3, 'to_account_id', v_settle, 'amount', 100,
    'schedule_unit', 'month', 'first_payment_date', m1::text, 'valid_to', m2::text, 'until_free_money', true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [7 create kombi]: %', v_res; END IF;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp2, 'amount', 4000, 'until_free_money', true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [7 set kombi]: %', v_res; END IF;
  RAISE NOTICE 'PASS [7 until_free_money nicht mit valid_to/amount]';

  -- (8) offene Kette -> NULL; kuenftige Betragsaenderung (Split) ist kein Ende
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__tfe split__', 'from_account_id', v_giro, 'to_account_id', v_p2p2, 'amount', 100,
    'schedule_unit', 'month', 'first_payment_date', m1::text)) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  IF finance.fn_recurring_last_due(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [8 offen]'; END IF;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'amount', 200, 'valid_from', m2::text));
  IF finance.fn_recurring_last_due(v_rp) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [8 Split ist kein Ende]'; END IF;
  RAISE NOTICE 'PASS [8 fn_recurring_last_due: offen NULL, Split kein Ende]';

  -- (9) beendete bzw. pausierte Kette -> not_running, Ende bleibt
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__tfe beendet__', v_p2p3, v_giro, -100, 'month', current_date - 60, current_date - 60, current_date - 10) RETURNING id INTO v_rp;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'until_free_money', true)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'not_running'
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM current_date - 10 THEN
    RAISE EXCEPTION 'FAIL [9 beendet]: %', v_res; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__tfe pause__', v_p2p3, v_giro, -100, 'month', m1, m1, 'paused') RETURNING id INTO v_rp;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'until_free_money', true)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'not_running' THEN RAISE EXCEPTION 'FAIL [9 pausiert]: %', v_res; END IF;
  RAISE NOTICE 'PASS [9 beendet/pausiert -> not_running]';

  -- (10) source_short: die Quelle faellt auch ohne den neuen Auftrag am selben Tag unter das Ziel-Geld
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_short__','p2p','EUR','active') RETURNING id INTO v_short;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_short, 1000, current_date - 5, 'other');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__tfe goal2__', 800, (current_date + interval '1 year')::date, 'active') RETURNING id INTO v_goal2;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal2, 'account_id', v_short, 'amount', 800));
  PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name', '__tfe vorhanden__', 'from_account_id', v_short, 'to_account_id', v_giro,
            'amount', 500, 'schedule_unit', 'month', 'schedule_day_of_month', 25, 'first_payment_date', m1::text));
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object('name', '__tfe spaeter__', 'from_account_id', v_short, 'to_account_id', v_giro,
            'amount', 10, 'schedule_unit', 'month', 'schedule_day_of_month', 25, 'first_payment_date', m2::text, 'until_free_money', true)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'source_short' OR (v_res->>'on_date')::date IS DISTINCT FROM m1 THEN
    RAISE EXCEPTION 'FAIL [10 source_short]: %', v_res; END IF;
  RAISE NOTICE 'PASS [10 source_short]';

  -- (11) Halbierung: ein spaeterer grosser Abgang teilt sich das freie Geld -> nicht der letzte Termin davor, sondern der zweite
  --      (10000 - 2 x 1000 - 8000 = 0; ein dritter Termin liesse den Stand unter 0 fallen)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe_bis__','p2p','EUR','active') RETURNING id INTO v_bis;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_bis, 10000, current_date - 5, 'other');
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__tfe gross__', v_bis, v_giro, -8000, 'month', (m1 + interval '5 months')::date - 15, (m1 + interval '5 months')::date - 15, (m1 + interval '5 months')::date - 14);
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object('name', '__tfe halb__', 'from_account_id', v_bis, 'to_account_id', v_giro,
            'amount', 1000, 'schedule_unit', 'month', 'schedule_day_of_month', 25, 'first_payment_date', m1::text, 'until_free_money', true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->'effective'->>'last_execution')::date IS DISTINCT FROM m2
     OR (v_res->'effective'->>'free_after')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [11 Halbierung]: %', v_res; END IF;
  RAISE NOTICE 'PASS [11 Halbierung findet den 2. Termin]';

  -- (12) Ampel neutral (Alltag unbekannt) -> kein drawdown, auch mit endendem Uebertrag
  PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name', '__tfe neutral__', 'from_account_id', v_spend, 'to_account_id', v_giro,
            'amount', 100, 'schedule_unit', 'month', 'first_payment_date', m1::text, 'valid_to', m2::text));
  v_f := finance.fn_account_funding(v_spend);
  IF v_f->>'state' IS DISTINCT FROM 'neutral' OR jsonb_typeof(v_f->'drawdown') IS DISTINCT FROM 'null' THEN
    RAISE EXCEPTION 'FAIL [12 neutral ohne drawdown]: %', v_f; END IF;
  RAISE NOTICE 'PASS [12 neutral ohne drawdown]';
END $$;

-- (13) direkt: nur ein laufender, freistehender Uebertrag zwischen eigenen Konten taugt -> eine normale Abbuchung und
--      eine Sparziel-Rate sind not_transfer; ein Uebertrag mit valid_to = heute (exklusiv) laeuft schon nicht mehr.
DO $$
DECLARE v_a INT; v_b INT; v_rp INT; v_res JSONB;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe13_a__','cash','EUR','active') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfe13_b__','p2p','EUR','active') RETURNING id INTO v_b;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__tfe13 abo__', v_a, -10, 'month', current_date + 5, current_date) RETURNING id INTO v_rp;
  v_res := finance.fn_transfer_free_end(v_rp);
  IF v_res->>'code' IS DISTINCT FROM 'not_transfer' THEN RAISE EXCEPTION 'FAIL [13a Abbuchung]: %', v_res; END IF;

  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__tfe13 zielrate__', v_a, v_b, -50, 'month', current_date + 5, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id)
    VALUES ('__tfe13 Ziel__', 1000, current_date + 300, v_rp);
  v_res := finance.fn_transfer_free_end(v_rp);
  IF v_res->>'code' IS DISTINCT FROM 'not_transfer' THEN RAISE EXCEPTION 'FAIL [13b Sparziel-Rate]: %', v_res; END IF;

  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__tfe13 endet heute__', v_b, v_a, -20, 'month', current_date - 20, current_date - 20, current_date) RETURNING id INTO v_rp;
  v_res := finance.fn_transfer_free_end(v_rp);
  IF v_res->>'code' IS DISTINCT FROM 'not_running' THEN RAISE EXCEPTION 'FAIL [13c endet heute]: %', v_res; END IF;
  RAISE NOTICE 'PASS [13 nur laufender freistehender Uebertrag]';
END $$;
ROLLBACK;
