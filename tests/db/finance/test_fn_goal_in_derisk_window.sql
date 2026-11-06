-- tests/db/finance/test_fn_goal_in_derisk_window.sql
-- finance.fn_goal_in_derisk_window(goal): die EINE Adresse der Regel "dieses Ziel ist zu kurzfristig fuers Depot"
-- (Fenster advisor.derisk_window_months, Default 60). Kalendermonate bis zum Zieldatum <= Fenster -> true, auch ein
-- schon verstrichenes Datum (Restmonate 0). Ohne Zieldatum -> NULL (der Aufrufer entscheidet, z. B. goal_no_target_date).
--   (1) Zieldatum in 24 Monaten -> true
--   (2) Zieldatum in 10 Jahren -> false
--   (3) Zieldatum vor 40 Tagen -> true
--   (4) kein Zieldatum (Instandhaltungsruecklage) -> NULL; unbekanntes Ziel -> NULL
BEGIN;
DO $$
DECLARE v_g1 int; v_g2 int; v_g3 int; v_g4 int; v_re int;
BEGIN
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gdw 1__', 6000, (current_date + interval '24 months')::date, 'active') RETURNING id INTO v_g1;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gdw 2__', 6000, (current_date + interval '10 years')::date, 'active') RETURNING id INTO v_g2;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gdw 3__', 6000, current_date - 40, 'active') RETURNING id INTO v_g3;
  INSERT INTO finance.real_estate (name) VALUES ('__gdw house__') RETURNING id INTO v_re;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, status)
    VALUES ('__gdw 4__', 'maintenance_reserve', v_re, 'active') RETURNING id INTO v_g4;

  IF finance.fn_goal_in_derisk_window(v_g1) IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1 24 Monate]'; END IF;
  IF finance.fn_goal_in_derisk_window(v_g2) IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [2 10 Jahre]'; END IF;
  IF finance.fn_goal_in_derisk_window(v_g3) IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [3 verstrichen]'; END IF;
  IF finance.fn_goal_in_derisk_window(v_g4) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4 ohne Datum]'; END IF;
  IF finance.fn_goal_in_derisk_window(-1) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4 unbekannt]'; END IF;
  RAISE NOTICE 'PASS fn_goal_in_derisk_window [24 Monate, 10 Jahre, verstrichen, ohne Datum, unbekannt]';
END $$;
ROLLBACK;
