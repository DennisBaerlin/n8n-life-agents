-- tests/db/finance/test_fn_savings_goal_derisk_status.sql
-- finance.fn_savings_goal_derisk_status(): Glide Path je aktivem Sparziel mit Depot-Anteil.
-- erlaubt = Ziel * min(Restmonate / Fenster, 1); Ueberschuss = Depot-Anteil - erlaubt; breach nur im
-- Fenster (Zieldatum in der Zukunft, Restmonate <= Fenster) und ueber der Toleranz (pp des Ziels).
--   (1) Ziel 6000 in 24 Monaten, 6000 im Depot, Fenster 60 -> erlaubt 2400, Ueberschuss 3600, breach
--   (2) Ziel in 10 Jahren -> nicht im Fenster, kein breach (erlaubt = Ziel)
--   (3) Ziel im laufenden Monat -> Restmonate 0, erlaubt 0, ganzer Depot-Anteil ist Ueberschuss
--   (4) vergangenes Zieldatum -> nicht im Fenster
--   (5) Ziel ohne Depot-Anteil -> keine Zeile; abgebrochenes Ziel -> keine Zeile
--   (6) aktiver verknuepfter Sparplan -> active_plan true
BEGIN;
DO $$
DECLARE v_settle int; v_depot int; v_g1 int; v_g2 int; v_g3 int; v_g4 int; v_g5 int; r record;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__gds_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__gds_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gds 1__', 6000, (date_trunc('month', current_date) + interval '24 months' + interval '10 days')::date, 'active') RETURNING id INTO v_g1;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gds 2__', 6000, (current_date + interval '10 years')::date, 'active') RETURNING id INTO v_g2;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gds 3__', 6000, (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date, 'active') RETURNING id INTO v_g3;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gds 4__', 6000, current_date - 40, 'active') RETURNING id INTO v_g4;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gds 5__', 6000, current_date + 300, 'cancelled') RETURNING id INTO v_g5;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    SELECT g, v_depot, 6000, 'EUR', 'manual' FROM unnest(ARRAY[v_g1, v_g2, v_g3, v_g4, v_g5]) g;

  -- (1)
  SELECT * INTO r FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g1;
  IF r.months_left IS DISTINCT FROM 24 OR r.allowed_depot_eur IS DISTINCT FROM 2400.00 OR r.excess_eur IS DISTINCT FROM 3600.00
     OR r.depot_share_eur IS DISTINCT FROM 6000 OR NOT r.in_window OR NOT r.breach THEN
    RAISE EXCEPTION 'FAIL derisk [1]: %', row_to_json(r); END IF;
  -- (2)
  SELECT * INTO r FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g2;
  IF r.in_window OR r.breach OR r.allowed_depot_eur IS DISTINCT FROM 6000.00 THEN RAISE EXCEPTION 'FAIL derisk [2]: %', row_to_json(r); END IF;
  -- (3)
  SELECT * INTO r FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g3;
  -- am Monatsletzten ist das Zieldatum heute (nicht mehr in der Zukunft) -> dann gilt Fall (4), hier nichts pruefen
  IF r.target_date > current_date AND (r.months_left IS DISTINCT FROM 0 OR r.allowed_depot_eur IS DISTINCT FROM 0.00
     OR r.excess_eur IS DISTINCT FROM 6000.00 OR NOT r.breach) THEN
    RAISE EXCEPTION 'FAIL derisk [3]: %', row_to_json(r); END IF;
  -- (4)
  SELECT * INTO r FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g4;
  IF r.in_window OR r.breach THEN RAISE EXCEPTION 'FAIL derisk [4]: %', row_to_json(r); END IF;
  -- (5)
  IF EXISTS (SELECT 1 FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g5) THEN RAISE EXCEPTION 'FAIL derisk [5 cancelled]'; END IF;
  -- (6)
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name','__gds_plan__','depot_name','__gds_depot__','isin','IE00B4L5Y983',
            'symbol','IUSQ','security_name','iShares MSCI World','amount',100,'schedule_interval',1,'schedule_unit','month',
            'first_payment_date',CURRENT_DATE::text));
  PERFORM finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g1, 'link_savings_plan_name', '__gds_plan__'));
  IF NOT (SELECT active_plan FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g1) THEN RAISE EXCEPTION 'FAIL derisk [6 active_plan]'; END IF;
  RAISE NOTICE 'PASS fn_savings_goal_derisk_status [Fenster, erlaubt/Ueberschuss, Restmonate 0, vergangen, abgebrochen, Sparplan]';

  -- (7) bewusste Ausnahme: p_goal liefert genau eine Zeile; Ruecklagen (kind) fehlen; ein Ziel nur mit
  --     Sparplan (Anteil 0) erscheint ohne breach; Zahlen fuer Rat, Spielraum und Beispiel-Verlust
  IF (SELECT count(*) FROM finance.fn_savings_goal_derisk_status(v_g1)) <> 1 THEN RAISE EXCEPTION 'FAIL derisk [7 p_goal]'; END IF;
  SELECT * INTO r FROM finance.fn_savings_goal_derisk_status(v_g1);
  IF r.needs_acceptance IS DISTINCT FROM true OR r.accepted OR r.headroom_eur IS DISTINCT FROM 0.00 OR r.headroom_eur_whole IS DISTINCT FROM 0
     OR r.stress_loss_eur IS DISTINCT FROM 1800.00 OR r.stress_pct IS DISTINCT FROM 30 OR r.fx_gap
     OR r.final_check_date IS DISTINCT FROM (r.target_date - interval '12 months')::date THEN
    RAISE EXCEPTION 'FAIL derisk [7 Zahlen]: %', row_to_json(r); END IF;
  UPDATE finance.savings_goals SET kind = 'emergency_reserve', target_date = NULL WHERE id = v_g2;
  IF EXISTS (SELECT 1 FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g2) THEN RAISE EXCEPTION 'FAIL derisk [7 Ruecklage]'; END IF;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gds Plan__', 6000, (date_trunc('month', current_date) + interval '30 months')::date, 'active') RETURNING id INTO v_g5;
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name','__gds_plan2__','depot_name','__gds_depot__','isin','IE00B4L5Y983',
            'symbol','IUSQ','security_name','iShares MSCI World','amount',100,'schedule_interval',1,'schedule_unit','month',
            'first_payment_date',CURRENT_DATE::text));
  PERFORM finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g5, 'link_savings_plan_name', '__gds_plan2__'));
  SELECT * INTO r FROM finance.fn_savings_goal_derisk_status(v_g5);
  IF r.goal_id IS NULL OR r.depot_share_eur IS DISTINCT FROM 0.00 OR r.breach OR r.needs_acceptance OR NOT r.active_plan OR NOT r.in_window THEN
    RAISE EXCEPTION 'FAIL derisk [7 nur Sparplan]: %', row_to_json(r); END IF;
  RAISE NOTICE 'PASS fn_savings_goal_derisk_status [7: p_goal, Ruecklagen ausgeschlossen, Ziel nur mit Sparplan, Zahlen]';
END $$;
ROLLBACK;
