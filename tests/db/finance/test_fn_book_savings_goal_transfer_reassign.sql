-- tests/db/finance/test_fn_book_savings_goal_transfer_reassign.sql
-- finance.fn_book_savings_goal_transfer direction='reassign' ("Sparziel umziehen"): die Zuordnung eines
-- Ziels wechselt das Konto ohne Geldbewegung (zwei Journal-Zeilen kind='manual', Netto-EUR 0 -> Fortschritt
-- unveraendert). Ziel darf ein Depot sein (Deckung = Marktwert, kein harter Block, shortfall auf der Karte);
-- saldo-basierte Ziele behalten den Freier-Saldo-Guard (eine Regel mit fn_book_savings_reservation).
--   (1) P2P -> Depot, amount leer = ganzer Anteil: Anteile, Netto 0, Post-State (free/market_value/shortfall)
--   (2) Teil-Umzug zurueck Depot -> P2P (Rueckgaengig-Weg)
--   (3) kurzfristiges Ziel -> Depot (bewusste Ausnahme statt goal_too_short_term): ok + Warnkarte,
--       ohne gezeigte Lage kein Stempel; (3b) mit depot_risk_shown aus dem Probelauf -> Eintrag accept mit genau den
--       gezeigten Werten + reminder_month
--   (4) Depot ohne Kurs: no_price
--   (5) Geld -> Geld ohne freies Geld: insufficient_free_balance (Guard der Reservierung)
--   (6) Notreserve -> Depot abgelehnt; Instandhaltung -> Depot abgelehnt
--   (7) USD-Quelle -> Depot: EUR-Umrechnung, Netto-EUR 0
--   (8) mehr als der Anteil: insufficient_share
--   (9) Ziel mit Monatsrate in die Quelle: effective.rate_pot_name gesetzt
--  (10) Depot-Name ueber to_account_name aufgeloest
--  (11) Quelle offen: das eine Konto mit Geld des Ziels; (12) mehrere -> missing_from + Kandidaten
--  (13) Notreserve von einem Konto wegziehen, das die Regel nicht (mehr) erfuellt
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_p2p INT; v_settle INT; v_depot INT; v_depot2 INT; v_cash INT; v_usd INT; v_giro INT;
  v_long INT; v_short INT; v_one INT; v_emerg INT; v_maint INT; v_rated INT; v_re INT;
  v_cur0 NUMERIC; v_cur1 NUMERIC; v_cnt INT; v_sh NUMERIC;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rea_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rea_settle__','cash','EUR','active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__rea_depot__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__rea_depot_noprice__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_depot2;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rea_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rea_usd__','cash','USD','active') RETURNING id INTO v_usd;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rea_giro__','cash','EUR','active') RETURNING id INTO v_giro;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'REATEST', 'Reassign Testwert', 100, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('REATEST', 100, 'EUR', current_date);   -- Marktwert 10000
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot2, 'REANOPRICE', 'Ohne Kurs', 10, 100, 'EUR');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'USD', 1.25, current_date);
  -- Salden: P2P 20000, USD 5000, cash 1000
  PERFORM finance.fn_book_transfer(jsonb_build_object('from_account_id', v_giro, 'to_account_id', v_p2p, 'from_amount', 20000));
  PERFORM finance.fn_book_transfer(jsonb_build_object('from_account_id', v_giro, 'to_account_id', v_cash, 'from_amount', 1000));
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
    VALUES (v_usd, 5000, current_date, 'other', '__rea usd start__');

  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rea long__', 30000, (current_date + interval '15 years')::date, 'active') RETURNING id INTO v_long;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rea short__', 3000, (current_date + interval '14 months')::date, 'active') RETURNING id INTO v_short;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_long, 'account_id', v_p2p, 'amount', 8000));
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_short, 'account_id', v_p2p, 'amount', 3000));
  SELECT current_amount INTO v_cur0 FROM finance.savings_goal_progress WHERE id = v_long;

  -- (1) P2P -> Depot, ganzer Anteil (amount leer)
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_id', v_p2p, 'to_account_id', v_depot, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1 ok]: %', v_res; END IF;
  IF (v_res->>'amount')::numeric IS DISTINCT FROM 8000 THEN RAISE EXCEPTION 'FAIL [1 amount derived]: %', v_res->>'amount'; END IF;
  IF (v_res->>'from_share')::numeric IS DISTINCT FROM 0 OR (v_res->>'to_share')::numeric IS DISTINCT FROM 8000 THEN
    RAISE EXCEPTION 'FAIL [1 shares]: %', v_res; END IF;
  IF (v_res->>'from_free_balance')::numeric IS DISTINCT FROM 17000 THEN RAISE EXCEPTION 'FAIL [1 free p2p]: erwartet 20000-3000, got %', v_res->>'from_free_balance'; END IF;
  IF (v_res->>'market_value')::numeric IS DISTINCT FROM 10000 OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [1 depot cover]: %', v_res; END IF;
  SELECT current_amount INTO v_cur1 FROM finance.savings_goal_progress WHERE id = v_long;
  IF v_cur1 IS DISTINCT FROM v_cur0 OR (v_res->>'current_amount')::numeric IS DISTINCT FROM v_cur0 THEN
    RAISE EXCEPTION 'FAIL [1 Fortschritt unveraendert]: % -> %', v_cur0, v_cur1; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE savings_goal_id = v_long;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [1 keine Geldbewegung]: % getaggte Tx', v_cnt; END IF;
  RAISE NOTICE 'PASS [1 reassign P2P -> Depot, ganzer Anteil, Netto 0, Post-State]';

  -- (2) Teil zurueck Depot -> P2P
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_id', v_depot, 'to_account_id', v_p2p, 'amount', 2000, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'from_share')::numeric IS DISTINCT FROM 6000
     OR (v_res->>'to_share')::numeric IS DISTINCT FROM 2000 OR (v_res->>'to_free_balance')::numeric IS DISTINCT FROM 15000 THEN
    RAISE EXCEPTION 'FAIL [2 zurueck]: %', v_res; END IF;
  RAISE NOTICE 'PASS [2 Teil-Umzug Depot -> P2P]';

  -- (3) kurzfristig -> Depot
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_short, 'from_account_id', v_p2p, 'to_account_id', v_depot, 'direction', 'reassign')) INTO v_res;
  -- Ziel 3000 in 14 Monaten: erlaubt 3000 * 14 / 60 = 700, 3000 im Depot liegt ueber erlaubt + 10 pp -> Warnkarte
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR NOT (v_res->'card_lines' @> '[{"value":"finance.note.goal_depot_risk"}]'::jsonb)
     OR v_res->>'card_approve_key' IS DISTINCT FROM 'finance.hitl.accept_depot_risk'
     OR (v_res->'effective'->'depot_risk_shown'->>'limit_eur')::numeric IS DISTINCT FROM 3000
     OR (v_res->'effective'->'depot_risk_shown'->>'allowed_eur')::numeric IS DISTINCT FROM 700
     OR v_res->'effective'->'depot_risk_shown'->>'target_date' IS DISTINCT FROM to_char(current_date + interval '14 months', 'YYYY-MM-DD')
     OR v_res ? 'depot_risk' THEN
    RAISE EXCEPTION 'FAIL [3 short: Warnkarte]: %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_short) THEN
    RAISE EXCEPTION 'FAIL [3 kein Stempel ohne gezeigte Lage]'; END IF;
  RAISE NOTICE 'PASS [3 kurzfristiges Ziel -> Depot: Warnkarte statt Verbot, kein Stempel]';
  -- (3b) zurueck aufs P2P, dann derselbe Umzug wie nach dem Tipp (Probelauf-effective im Payload)
  PERFORM finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_short, 'from_account_id', v_depot, 'to_account_id', v_p2p, 'direction', 'reassign'));
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_short, 'from_account_id', v_p2p, 'to_account_id', v_depot, 'direction', 'reassign',
    'depot_risk_shown', v_res->'effective'->'depot_risk_shown')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->'depot_risk'->>'reminder_month' IS DISTINCT FROM to_char(current_date + interval '2 months', 'YYYY-MM')
     OR v_res->'card_lines' IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3b Stempel-Return]: %', v_res; END IF;
  IF (SELECT count(*) FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_short AND event = 'accept'
        AND limit_eur = 3000 AND allowed_eur = 700 AND target_date = (current_date + interval '14 months')::date) <> 1 THEN
    RAISE EXCEPTION 'FAIL [3b Eintrag mit den gezeigten Werten]'; END IF;
  IF NOT (SELECT accepted FROM finance.fn_savings_goal_derisk_status(v_short)) THEN RAISE EXCEPTION 'FAIL [3b accepted]'; END IF;
  -- zurueck, damit die Folgefaelle den Ausgangsstand sehen
  PERFORM finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_short, 'from_account_id', v_depot, 'to_account_id', v_p2p, 'direction', 'reassign'));
  SELECT share_native INTO v_sh FROM finance.savings_goal_account_share WHERE goal_id = v_short AND account_id = v_p2p;
  IF v_sh IS DISTINCT FROM 3000 THEN RAISE EXCEPTION 'FAIL [3b zurueck]: %', v_sh; END IF;
  RAISE NOTICE 'PASS [3b Umzug nach dem Tipp: Eintrag accept mit Grenze 3000, erlaubt 700, letzter Check in 2 Monaten]';

  -- (4) Depot ohne Kurs
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_id', v_p2p, 'to_account_id', v_depot2, 'direction', 'reassign')) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'no_price' THEN RAISE EXCEPTION 'FAIL [4 no_price]: %', v_res; END IF;
  RAISE NOTICE 'PASS [4 Depot ohne Kurs -> no_price]';

  -- (5) Geld -> Geld: cash hat 1000 frei, 2000 umziehen -> Guard der Reservierung
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_id', v_p2p, 'to_account_id', v_cash, 'direction', 'reassign')) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'insufficient_free_balance' THEN RAISE EXCEPTION 'FAIL [5 free guard]: %', v_res; END IF;
  RAISE NOTICE 'PASS [5 Geld -> Geld ohne freies Geld abgelehnt]';

  -- (6) Notreserve / Instandhaltung -> Depot
  INSERT INTO finance.savings_goals (name, kind, target_amount, status)
    VALUES ('__rea emerg__', 'emergency_reserve', 5000, 'active') RETURNING id INTO v_emerg;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_emerg, 'account_id', v_cash, 'amount', 500));
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_emerg, 'from_account_id', v_cash, 'to_account_id', v_depot, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6 Notreserve]: %', v_res; END IF;
  INSERT INTO finance.real_estate (name) VALUES ('__rea house__') RETURNING id INTO v_re;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, status)
    VALUES ('__rea maint__', 'maintenance_reserve', v_re, 'active') RETURNING id INTO v_maint;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_maint, 'account_id', v_p2p, 'amount', 500));
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_maint, 'from_account_id', v_p2p, 'to_account_id', v_depot, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6 Instandhaltung]: %', v_res; END IF;
  RAISE NOTICE 'PASS [6 Notreserve/Instandhaltung -> Depot abgelehnt]';

  -- (7) USD-Quelle -> Depot: 1250 USD = 1000 EUR
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_long, 'account_id', v_usd, 'amount', 1250));
  SELECT current_amount INTO v_cur0 FROM finance.savings_goal_progress WHERE id = v_long;
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_id', v_usd, 'to_account_id', v_depot, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'amount')::numeric IS DISTINCT FROM 1250
     OR (v_res->>'to_share')::numeric IS DISTINCT FROM 7000 THEN RAISE EXCEPTION 'FAIL [7 USD]: %', v_res; END IF;
  SELECT current_amount INTO v_cur1 FROM finance.savings_goal_progress WHERE id = v_long;
  IF v_cur1 IS DISTINCT FROM v_cur0 THEN RAISE EXCEPTION 'FAIL [7 Netto-EUR]: % -> %', v_cur0, v_cur1; END IF;
  RAISE NOTICE 'PASS [7 USD -> Depot, EUR-Umrechnung, Netto 0]';

  -- (8) mehr als der Anteil
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_id', v_p2p, 'to_account_id', v_depot, 'amount', 99999, 'direction', 'reassign')) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'insufficient_share' OR (v_res->>'available')::numeric IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'FAIL [8 share]: %', v_res; END IF;
  RAISE NOTICE 'PASS [8 mehr als der Anteil -> insufficient_share]';

  -- (9) Ziel mit Monatsrate in den P2P-Topf: Karte nennt den Topf, in den die Rate weiter fliesst
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__rea rated__','target_amount',50000,'target_date',(current_date + interval '20 years')::date::text,
    'monthly_savings_rate',100,'account_id',v_giro,'reserve_account_id',v_p2p,
    'schedule_day_of_month',1,'first_payment_date',current_date::text)) INTO v_res;
  v_rated := (v_res->>'goal_id')::int;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_rated, 'account_id', v_p2p, 'amount', 1000));
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_rated, 'from_account_id', v_p2p, 'to_account_id', v_depot, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->'effective'->>'rate_pot_name' IS DISTINCT FROM '__rea_p2p__' THEN
    RAISE EXCEPTION 'FAIL [9 rate pot]: %', v_res; END IF;
  RAISE NOTICE 'PASS [9 Monatsrate laeuft weiter in den alten Topf -> Karte nennt ihn]';

  -- (10) Depot-Name ueber to_account_name (reassign darf Depots aufloesen; relocate weiter nicht)
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_name', '__rea_p2p__', 'to_account_name', '__rea_depot__', 'amount', 500, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [10 name]: %', v_res; END IF;
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_long, 'from_account_name', '__rea_p2p__', 'to_account_name', '__rea_depot__', 'amount', 500, 'direction', 'relocate')) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'depot_not_allowed' THEN RAISE EXCEPTION 'FAIL [10 relocate depot]: %', v_res; END IF;
  RAISE NOTICE 'PASS [10 Depot-Name bei reassign aufgeloest, bei relocate abgelehnt]';

  -- (11) Quelle offen: das eine Konto mit Geld des Ziels wird abgeleitet (Ziel liegt nur auf P2P)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rea one__', 9000, (current_date + interval '12 years')::date, 'active') RETURNING id INTO v_one;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_one, 'account_id', v_p2p, 'amount', 400));
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_one, 'to_account_id', v_depot, 'amount', 100, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->'effective'->>'from_account_id')::int IS DISTINCT FROM v_p2p THEN
    RAISE EXCEPTION 'FAIL [11 Quelle abgeleitet]: %', v_res; END IF;
  RAISE NOTICE 'PASS [11 Quelle abgeleitet]';

  -- (12) Geld des Ziels auf P2P und Depot, Ziel-Konto cash, Quelle offen -> missing_from + 2 Kandidaten
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_one, 'to_account_id', v_cash, 'direction', 'reassign')) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'missing_from' OR jsonb_array_length(v_res->'candidates') <> 2 THEN
    RAISE EXCEPTION 'FAIL [12 missing_from]: %', v_res; END IF;
  RAISE NOTICE 'PASS [12 mehrere Quellen -> missing_from + Kandidaten]';

  -- (13) Notreserve liegt auf einem Konto, das die Regel nicht erfuellt (P2P) -> Wegziehen auf ein Geld-Konto geht
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    VALUES (v_emerg, v_p2p, 100, 'EUR', 'manual');
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_emerg, 'from_account_id', v_p2p, 'to_account_id', v_cash, 'direction', 'reassign')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'from_share')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [13 Notreserve wegziehen]: %', v_res; END IF;
  RAISE NOTICE 'PASS [13 Notreserve von falschem Konto wegziehen]';
END $$;

-- (14) Geld (EUR) -> Geld (USD): der Ziel-Anteil wird in USD umgerechnet (400 EUR x 1.25 = 500 USD); die Quelle ist
--      nicht der Raten-Topf des Ziels -> rate_pot_name bleibt leer.
DO $$
DECLARE v_res JSONB; v_giro INT; v_pot INT; v_eur INT; v_usd INT; v_goal INT;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE base_currency = 'EUR' AND quote_currency = 'USD';
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'USD', 1.25, current_date);
  v_giro := (finance.fn_create_account('{"name":"__rea14_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__rea14_pot__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rea14_eur__','cash','EUR','active') RETURNING id INTO v_eur;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rea14_usd__','cash','USD','active') RETURNING id INTO v_usd;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_eur, 1000, current_date - 1, 'other'), (v_usd, 1000, current_date - 1, 'other');
  v_goal := (finance.fn_create_savings_goal(jsonb_build_object(
    'name','__rea14_goal__','target_amount',5000,'target_date',(current_date + 900)::text,
    'monthly_savings_rate',50,'account_id',v_giro,'reserve_account_id',v_pot,
    'schedule_day_of_month',1,'first_payment_date',(current_date + 3)::text))->>'goal_id')::int;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_eur, 'amount', 400));

  v_res := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'direction', 'reassign',
    'from_account_id', v_eur, 'to_account_id', v_usd, 'amount', 400));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'to_share')::numeric IS DISTINCT FROM 500
     OR v_res->'effective'->>'rate_pot_name' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [14 EUR -> USD]: erwartet to_share 500 USD, kein rate_pot_name, got %', v_res; END IF;
  RAISE NOTICE 'PASS [14 EUR -> USD umgerechnet, Quelle ohne Raten-Topf]';
END $$;

ROLLBACK;
