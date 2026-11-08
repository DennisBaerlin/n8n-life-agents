-- tests/db/finance/test_fn_goal_depot_risk_fold.sql
-- finance.fn_goal_depot_risk_fold(p_goal, p_shown, p_force) + fn_savings_goal_derisk_status (2026-11-06): ein Sparziel
-- kurz vor dem Termin im Depot ist eine bewusste, festgehaltene Ausnahme statt eines Verbots.
--   (F1) ueber dem Pfad -> Warnkarte mit Zahlen (Rat abgerundet, Beispiel-Verlust genau, digits 0), Knopf-Key,
--        effective.depot_risk_shown Cent-genau; ohne gezeigte Lage kein Eintrag
--   (F2) Probelauf ueber core.fn_dry_run hinterlaesst keinen Eintrag
--   (F3) echter Write mit depot_risk_shown -> Eintrag accept mit genau den gezeigten Werten, reminder_month; danach
--        Senken + wieder Erhoehen bis zur Grenze -> keine Warnung (bestaetigt und unveraendert)
--   (F4) Kursaenderung hebt die Entscheidung nie auf (Grenze in eingezahlten EUR)
--   (F5) mehr als die Grenze -> accepted false, Warnung wieder da; veraltete gezeigte Lage -> kein Stempel
--   (F6) frueheres Zieldatum -> accepted false
--   (F7) revoke hebt auf
--   (F8) im Fenster, im Pfad -> weicher Hinweis, kein Merkmal; (F9) ausserhalb des Fensters -> []
--   (F10) Kurs-Luecke -> nur Hinweis, kein needs_acceptance
--   (F11) Shape-CHECK als Backstop (auch NULL in limit_eur/allowed_eur)
--   (F12) Rat befolgen loest keine Karte aus (Leitung 2026-11-06): Umzug von genau headroom_eur_whole ins Depot ->
--         needs_acceptance false, keine Warnzeile, kein Eintrag; Verkauf des abgerundeten Vorschlags -> breach false
--   (F13) Ablauf: Entscheidung vor dem Stichtag (Termin - 12 Monate) laeuft ab, nach dem Stichtag gilt sie bis zum Termin
BEGIN;
DO $$
DECLARE
  v_settle int; v_depot int; v_p2p int; v_g int; v_g2 int; v_g3 int; v_g4 int; v_g5 int;
  v_r jsonb; v_line jsonb; v_shown jsonb; s record; v_cnt int; v_ok boolean;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__drf_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__drf_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'DRFTEST', 'Testfonds', 1000, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DRFTEST', 100, 'EUR', current_date);
  -- Ziel 6000 in 24 Monaten: erlaubt 6000 * 24 / 60 = 2400
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf Reise__', 6000, (date_trunc('month', current_date) + interval '24 months' + interval '10 days')::date, 'active')
    RETURNING id INTO v_g;

  -- (F1)
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 6000));
  v_line := v_r->'card_lines'->0;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_line->>'value' IS DISTINCT FROM 'finance.note.goal_depot_risk'
     OR (v_line->'params'->'allowed'->>'value')::numeric IS DISTINCT FROM 2400 OR (v_line->'params'->'allowed'->>'digits')::int IS DISTINCT FROM 0
     OR (v_line->'params'->'stress_loss'->>'value')::numeric IS DISTINCT FROM 1800 OR (v_line->'params'->'stress_loss'->>'digits')::int IS DISTINCT FROM 0
     OR (v_line->'params'->'months'->>'value')::int IS DISTINCT FROM 24
     OR (v_line->'params'->'stress_pct'->>'value')::numeric IS DISTINCT FROM 30
     OR v_line->'params'->'reminder'->>'value' IS DISTINCT FROM to_char((date_trunc('month', current_date) + interval '12 months' + interval '10 days')::date, 'YYYY-MM')
     OR v_r->>'card_approve_key' IS DISTINCT FROM 'finance.hitl.accept_depot_risk'
     OR (v_r->'effective'->'depot_risk_shown'->>'limit_eur')::numeric IS DISTINCT FROM 6000
     OR (v_r->'effective'->'depot_risk_shown'->>'allowed_eur')::numeric IS DISTINCT FROM 2400 THEN
    RAISE EXCEPTION 'FAIL [F1 Warnkarte]: %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_g) THEN
    RAISE EXCEPTION 'FAIL [F1 kein Eintrag ohne gezeigte Lage]'; END IF;
  v_shown := v_r->'effective'->'depot_risk_shown';
  RAISE NOTICE 'PASS [F1 Warnkarte mit Rat 2400, Beispiel-Verlust 1800, ganze Euro, Knopf, gezeigte Lage]';

  -- (F2) Probelauf: Senken auf 0 und wieder auf 6000 waere ein Write; der Probelauf rollt alles zurueck
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 0));
  v_r := core.fn_dry_run('finance.fn_book_savings_reservation(jsonb)'::regprocedure,
           jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 6000, 'depot_risk_shown', v_shown));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR EXISTS (SELECT 1 FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_g) THEN
    RAISE EXCEPTION 'FAIL [F2 Probelauf hinterlaesst nichts]: %', v_r; END IF;
  RAISE NOTICE 'PASS [F2 Probelauf ohne Eintrag]';

  -- (F3) echter Write nach dem Tipp
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 6000,
           'depot_risk_shown', v_shown));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->'card_lines' IS DISTINCT FROM '[]'::jsonb
     OR v_r->'depot_risk'->>'reminder_month' IS DISTINCT FROM to_char((date_trunc('month', current_date) + interval '12 months')::date, 'YYYY-MM') THEN
    RAISE EXCEPTION 'FAIL [F3 Stempel-Return]: %', v_r; END IF;
  IF (SELECT count(*) FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_g AND event = 'accept' AND limit_eur = 6000
        AND allowed_eur = 2400 AND target_date = (v_shown->>'target_date')::date) <> 1 THEN
    RAISE EXCEPTION 'FAIL [F3 Eintrag mit den gezeigten Werten]'; END IF;
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF NOT s.accepted OR s.needs_acceptance OR s.accepted_on IS DISTINCT FROM current_date OR s.limit_eur IS DISTINCT FROM 6000 THEN
    RAISE EXCEPTION 'FAIL [F3 Status]: %', row_to_json(s); END IF;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 5000));
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 6000));
  IF v_r->'card_lines' IS DISTINCT FROM '[]'::jsonb OR v_r ? 'effective' THEN
    RAISE EXCEPTION 'FAIL [F3 zweiter Write im Rahmen ohne Warnung]: %', v_r; END IF;
  RAISE NOTICE 'PASS [F3 Stempel mit gezeigten Werten, letzter Check in 12 Monaten, zweiter Write im Rahmen still]';

  -- (F4) Kurs faellt um die Haelfte -> Entscheidung bleibt
  UPDATE finance.market_prices SET price = 50 WHERE symbol = 'DRFTEST';
  IF NOT (SELECT accepted FROM finance.fn_savings_goal_derisk_status(v_g)) THEN RAISE EXCEPTION 'FAIL [F4 Kurs hebt auf]'; END IF;
  RAISE NOTICE 'PASS [F4 Kursaenderung hebt die Entscheidung nicht auf]';

  -- (F5) mehr als bestaetigt
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 7000,
           'depot_risk_shown', v_shown));   -- veraltete Lage (Grenze 6000)
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF s.accepted OR NOT s.needs_acceptance OR (SELECT count(*) FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_g) <> 1
     OR v_r->'card_lines'->0->>'value' IS DISTINCT FROM 'finance.note.goal_depot_risk' THEN
    RAISE EXCEPTION 'FAIL [F5 ueber der Grenze]: % / %', row_to_json(s), v_r; END IF;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 6000));
  RAISE NOTICE 'PASS [F5 ueber der Grenze: nicht mehr bestaetigt, veraltete Lage stempelt nicht]';

  -- (F6) frueheres Zieldatum
  UPDATE finance.savings_goals SET target_date = target_date - 40 WHERE id = v_g;
  IF (SELECT accepted FROM finance.fn_savings_goal_derisk_status(v_g)) THEN RAISE EXCEPTION 'FAIL [F6 frueheres Datum]'; END IF;
  UPDATE finance.savings_goals SET target_date = target_date + 40 WHERE id = v_g;
  IF NOT (SELECT accepted FROM finance.fn_savings_goal_derisk_status(v_g)) THEN RAISE EXCEPTION 'FAIL [F6 zurueck]'; END IF;
  RAISE NOTICE 'PASS [F6 frueheres Zieldatum hebt auf]';

  -- (F7) revoke
  INSERT INTO finance.savings_goal_risk_decisions (savings_goal_id, event) VALUES (v_g, 'revoke');
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF s.accepted OR s.acceptance_expired OR NOT s.needs_acceptance OR s.limit_eur IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [F7 revoke]: %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS [F7 revoke hebt auf]';

  -- (F8) im Pfad: Ziel 10000 in 48 Monaten, erlaubt 8000, 7000 im Depot
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf Auto__', 10000, (date_trunc('month', current_date) + interval '48 months' + interval '10 days')::date, 'active')
    RETURNING id INTO v_g2;
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g2, 'account_id', v_depot, 'amount', 7000));
  IF v_r->'card_lines'->0->>'value' IS DISTINCT FROM 'finance.note.goal_derisk_window' OR v_r ? 'effective' OR v_r ? 'card_approve_key'
     OR v_r->'card_lines'->0->'params'->'month'->>'value' IS DISTINCT FROM to_char((date_trunc('month', current_date) + interval '48 months')::date, 'YYYY-MM') THEN
    RAISE EXCEPTION 'FAIL [F8 weicher Hinweis]: %', v_r; END IF;
  -- (F9) ausserhalb des Fensters
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf Rente__', 10000, (current_date + interval '8 years')::date, 'active') RETURNING id INTO v_g3;
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g3, 'account_id', v_depot, 'amount', 9000));
  IF v_r->'card_lines' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [F9 ausserhalb]: %', v_r; END IF;
  RAISE NOTICE 'PASS [F8 im Pfad weicher Hinweis, F9 ausserhalb nichts]';

  -- (F10) Kurs-Luecke: ein Depot-Bein in CHF ohne Kurs
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf Franken__', 6000, (date_trunc('month', current_date) + interval '24 months' + interval '10 days')::date, 'active')
    RETURNING id INTO v_g4;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    VALUES (v_g4, v_depot, 5000, 'EUR', 'manual'), (v_g4, v_depot, 100, 'CHF', 'sparplan_buy');
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g4);
  v_r := finance.fn_goal_depot_risk_fold(v_g4, NULL);
  IF NOT s.fx_gap OR s.needs_acceptance OR v_r->'card_lines'->0->>'value' IS DISTINCT FROM 'finance.note.goal_depot_risk_fx' OR v_r ? 'effective' THEN
    RAISE EXCEPTION 'FAIL [F10 Kurs-Luecke]: % / %', row_to_json(s), v_r; END IF;
  -- (F10b) nur ein Bein ohne Kurs (Anteil faellt ganz aus der Summe) -> die Zeile bleibt, der Hinweis kommt (Code-Review)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf Franken nur__', 6000, (date_trunc('month', current_date) + interval '24 months' + interval '10 days')::date, 'active')
    RETURNING id INTO v_g5;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    VALUES (v_g5, v_depot, 100, 'CHF', 'sparplan_buy');
  v_r := finance.fn_goal_depot_risk_fold(v_g5, NULL);
  IF v_r->'card_lines'->0->>'value' IS DISTINCT FROM 'finance.note.goal_depot_risk_fx' THEN
    RAISE EXCEPTION 'FAIL [F10b nur Kurs-Luecke]: %', v_r; END IF;
  RAISE NOTICE 'PASS [F10 Kurs-Luecke: nur Hinweis, nichts festhalten; auch ohne bekannten Anteil]';

  -- (F11) Shape-CHECK
  v_ok := false;
  BEGIN
    INSERT INTO finance.savings_goal_risk_decisions (savings_goal_id, event, target_date, limit_eur, allowed_eur)
      VALUES (v_g, 'accept', current_date, NULL, 100);
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [F11 accept ohne Grenze]'; END IF;
  v_ok := false;
  BEGIN
    INSERT INTO finance.savings_goal_risk_decisions (savings_goal_id, event, target_date, limit_eur, allowed_eur)
      VALUES (v_g, 'revoke', current_date, 100, 100);
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [F11 revoke mit Werten]'; END IF;
  RAISE NOTICE 'PASS [F11 Shape-CHECK in beide Richtungen]';
END $$;
ROLLBACK;

-- (F12) Rat befolgen loest keine Karte aus; (F13) Ablauf der Entscheidung
BEGIN;
DO $$
DECLARE
  v_settle int; v_depot int; v_p2p int; v_g int; v_g2 int; v_r jsonb; s record; v_whole numeric;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__drf_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;
  v_settle := (finance.fn_create_account('{"name":"__drf_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_book_transfer(jsonb_build_object('from_account_id', v_settle, 'to_account_id', v_p2p, 'from_amount', 30000));
  v_settle := (finance.fn_create_account('{"name":"__drf_settle2__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__drf_depot2__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'DRFTEST2', 'Testfonds', 1000, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DRFTEST2', 100, 'EUR', current_date);
  -- Ziel 20000 in 28 Monaten: erlaubt 20000 * 28 / 60 = 9333,33 (krummer Spielraum)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf Haus__', 20000, (date_trunc('month', current_date) + interval '28 months' + interval '10 days')::date, 'active')
    RETURNING id INTO v_g;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_p2p, 'amount', 20000));
  -- ein Depot-Anteil von 1 EUR legt die Zeile an (der Rest liegt noch auf dem P2P)
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 1));
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF s.allowed_depot_eur IS DISTINCT FROM 9333.33 OR s.headroom_eur IS DISTINCT FROM 9332.33 OR s.headroom_eur_whole IS DISTINCT FROM 9332
     OR s.stress_loss_eur IS DISTINCT FROM 0.30 THEN
    RAISE EXCEPTION 'FAIL [F12 headroom genau + abgerundet]: %', row_to_json(s); END IF;
  v_whole := s.headroom_eur_whole;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id', v_g, 'from_account_id', v_p2p, 'to_account_id', v_depot, 'amount', v_whole, 'direction', 'reassign'));
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR s.depot_share_eur IS DISTINCT FROM 9333.00 OR s.breach OR s.needs_acceptance
     OR v_r->'card_lines' @> '[{"value":"finance.note.goal_depot_risk"}]'::jsonb OR v_r->'effective' ? 'depot_risk_shown'
     OR EXISTS (SELECT 1 FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_g) THEN
    RAISE EXCEPTION 'FAIL [F12 Rat befolgt -> keine Karte]: % / %', row_to_json(s), v_r; END IF;
  -- Berater-Vorschlag: 14000 im Depot, Ueberschuss 4666,67 -> abgerundeter Verkauf 4666 laesst keine Mahnung zurueck
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 14000));
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF NOT s.breach OR s.excess_eur IS DISTINCT FROM 4666.67 THEN RAISE EXCEPTION 'FAIL [F12 Ausgangslage Verkauf]: %', row_to_json(s); END IF;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 14000 - floor(s.excess_eur)));
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF s.breach THEN RAISE EXCEPTION 'FAIL [F12 Verkauf nach Vorschlag]: %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS [F12 Rat befolgen: Umzug von headroom_eur_whole und Verkauf des abgerundeten Vorschlags loesen nichts aus]';

  -- (F13) Ablauf: Stichtag = Termin - 12 Monate
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_depot, 'amount', 14000));
  INSERT INTO finance.savings_goal_risk_decisions (savings_goal_id, event, decided_at, target_date, limit_eur, allowed_eur)
    SELECT v_g, 'accept', now() - interval '3 months', g.target_date, 14000, 9333.33 FROM finance.savings_goals g WHERE g.id = v_g;
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF NOT s.accepted OR s.acceptance_expired
     OR s.final_check_date IS DISTINCT FROM ((date_trunc('month', current_date) + interval '16 months' + interval '10 days')::date) THEN
    RAISE EXCEPTION 'FAIL [F13 gilt vor dem Stichtag]: %', row_to_json(s); END IF;
  -- Termin in 6 Monaten (Datum frueher hebt ohnehin auf -> Snapshot-Datum mitziehen, damit nur der Ablauf greift)
  UPDATE finance.savings_goals SET target_date = (date_trunc('month', current_date) + interval '6 months' + interval '10 days')::date WHERE id = v_g;
  -- Stichtag liegt jetzt 6 Monate zurueck; entschieden vor 9 Monaten = vor dem Stichtag
  UPDATE finance.savings_goal_risk_decisions SET target_date = (SELECT target_date FROM finance.savings_goals WHERE id = v_g),
         decided_at = now() - interval '9 months' WHERE savings_goal_id = v_g;
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF s.accepted OR NOT s.acceptance_expired OR NOT s.needs_acceptance THEN
    RAISE EXCEPTION 'FAIL [F13 abgelaufen]: %', row_to_json(s); END IF;
  -- nach dem Stichtag entschieden -> gilt bis zum Termin; die Karte zeigt die Schluss-Fassung ohne weitere Erinnerung
  v_r := finance.fn_goal_depot_risk_fold(v_g, NULL);
  IF v_r->'card_lines'->0->>'value' IS DISTINCT FROM 'finance.note.goal_depot_risk_final' THEN
    RAISE EXCEPTION 'FAIL [F13 Schluss-Fassung der Karte]: %', v_r; END IF;
  v_r := finance.fn_goal_depot_risk_fold(v_g, v_r->'effective'->'depot_risk_shown');
  IF v_r->'depot_risk' IS DISTINCT FROM '{"reminder_month": null}'::jsonb THEN RAISE EXCEPTION 'FAIL [F13 kein reminder im letzten Jahr]: %', v_r; END IF;
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF NOT s.accepted OR s.needs_acceptance THEN RAISE EXCEPTION 'FAIL [F13 nach dem Stichtag gilt bis zum Termin]: %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS [F13 Ablauf am Stichtag, Entscheidung im letzten Jahr gilt bis zum Termin]';
END $$;

-- (F14) Stichtag heute (Termin genau in 12 Monaten) -> schon Schluss-Fassung; (F15) mit aktivem Sparplan ist die
-- Freigabe-Grenze das Ziel, nicht der kleinere Anteil
DO $$
DECLARE
  v_settle int; v_depot int; v_rp int; v_a int; v_c int; v_r jsonb;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__drf2_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__drf2_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'DRFTWO', 'Testfonds', 1000, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DRFTWO', 100, 'EUR', current_date);

  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf2 a__', 6000, (current_date + interval '12 months')::date, 'active') RETURNING id INTO v_a;
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_a, 'account_id', v_depot, 'amount', 6000));
  IF v_r->'card_lines'->0->>'value' IS DISTINCT FROM 'finance.note.goal_depot_risk_final' THEN
    RAISE EXCEPTION 'FAIL [F14 Stichtag heute -> Schluss-Fassung]: %', v_r; END IF;


  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drf2 c__', 6000, (current_date + interval '24 months')::date, 'active') RETURNING id INTO v_c;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__drf2 plan__', v_settle, -100, 'month', current_date - 25, current_date - 25) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, savings_goal_id, status)
    VALUES ('__drf2 plan__', v_depot, 'DRFTWO', 'Testfonds', v_rp, v_c, 'active');
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_c, 'account_id', v_depot, 'amount', 3000));
  v_r := finance.fn_goal_depot_risk_fold(v_c, NULL, true);
  IF (v_r->'effective'->'depot_risk_shown'->>'limit_eur')::numeric IS DISTINCT FROM 6000 THEN
    RAISE EXCEPTION 'FAIL [F15 Sparplan -> Grenze = Ziel 6000]: %', v_r; END IF;
  RAISE NOTICE 'PASS [F14/F15 Stichtag heute, Sparplan-Grenze = Ziel]';
END $$;
ROLLBACK;
