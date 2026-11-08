-- tests/db/finance/test_recalc_savings_goal.sql
-- Zweitrechnung Sparziel und Notreserve: Erwartungswerte schriftlich hergeleitet, nicht aus den fns abgeschrieben.
-- Sparrate, Fachregel: Rest = Ziel - schon gespart; Rate = Rest / Anzahl Raten, auf den Cent AUFgerundet (sonst
--   bleibt das Ziel um Cent unerreicht); Laufzeit aus einer Rate = ceil(Rest / Rate) Raten.
--   (1) Raten-getrieben: Ziel 12.000, gespart 2.000, 400 je Monat ab 10.02.2027 -> 25 Raten, die 25. am 10.02.2029,
--       Ziel erreicht -> Zieldatum 10.03.2029 (ein Monat nach der letzten Rate, Konvention "Raten vor dem Zieldatum")
--   (2) Ziel-getrieben, Zieltag vor dem Abbuchungstag: ab 15.02.2027 bis 10.08.2028 -> 18 Raten (15.02.2027 bis
--       15.07.2028), 10.000 / 18 = 555,555... -> 555,56 (18 x 555,56 = 10.000,08 >= 10.000)
--   (3) Monatsende: ab 31.01.2028 (Schaltjahr) 300 je Monat auf 1.000 -> 4 Raten -> Zieldatum 31.05.2028
--   (4) Schon gedeckt (gespart >= Ziel) -> Rate 0, 0 Monate; Rate 0 als Eingabe -> {ok:false}
-- Sparziel-Fortschritt, Fachregel linearer Zeit-Soll: Soll % = vergangene Tage / Gesamttage; Rueckstand = Soll - Ist.
--   (5) Ziel 12.000, angelegt vor 73 Tagen, Zieldatum in 292 Tagen (365 gesamt), 1.500 zugeordnet:
--       Soll 20,00 %, Ist 12,50 %, Drift 7,50 Prozentpunkte, Rueckstand 0,2 x 12.000 - 1.500 = 900,00;
--       Nachhol-Rate = 10.500 / 10 Restmonate (292 / 30,4375 = 9,59 -> 10 Monatstermine) = 1.050,00
-- Notreserve, Fachregel: Ziel = Monate x monatliche Pflichtausgaben (feste Zahlungen auf den Monat normalisiert,
--   365,25-Tage-Jahr; Sparraten zaehlen nicht, sie lassen sich im Notfall aussetzen):
--   (6) Miete 950 / Monat + Kfz 444 / Jahr (= 37,00) + Verein 12 / Woche (= 12 x 30,4375 / 7 = 52,18) = 1.039,18;
--       Sparrate 200 / Monat aufs Tagesgeld zaehlt nicht. 4 Monate -> 4.156,72; 3 / 6 Monate -> 3.117,54 / 6.235,08.
--       Gedeckt 3.000 (Startbestand auf dem Tagesgeld) -> Luecke 1.156,72, Zustand warn.
-- Self-contained, Werte erfunden.
BEGIN;

DO $$
DECLARE
  v jsonb;
BEGIN
  v := finance.fn_savings_rate_schedule('{"target_amount":12000,"already_saved":2000,"first_payment_date":"2027-02-10","monthly_savings_rate":400}');
  IF (v->>'months')::int IS DISTINCT FROM 25 OR (v->>'target_date')::date IS DISTINCT FROM DATE '2029-03-10' THEN
    RAISE EXCEPTION 'FAIL [1] Raten-getrieben: %', v; END IF;
  v := finance.fn_savings_rate_schedule('{"target_amount":12000,"already_saved":2000,"first_payment_date":"2027-02-15","target_date":"2028-08-10"}');
  IF (v->>'months')::int IS DISTINCT FROM 18 OR (v->>'monthly_rate')::numeric IS DISTINCT FROM 555.56 THEN
    RAISE EXCEPTION 'FAIL [2] Ziel-getrieben: %', v; END IF;
  v := finance.fn_savings_rate_schedule('{"target_amount":1000,"first_payment_date":"2028-01-31","monthly_savings_rate":300}');
  IF (v->>'months')::int IS DISTINCT FROM 4 OR (v->>'target_date')::date IS DISTINCT FROM DATE '2028-05-31' THEN
    RAISE EXCEPTION 'FAIL [3] Monatsende: %', v; END IF;
  v := finance.fn_savings_rate_schedule(jsonb_build_object('target_amount', 12000, 'already_saved', 12500,
         'first_payment_date', current_date + 10, 'target_date', current_date + 400));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'monthly_rate')::numeric <> 0 OR (v->>'months')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [4a] gedeckt: %', v; END IF;
  v := finance.fn_savings_rate_schedule('{"target_amount":1000,"first_payment_date":"2028-01-31","monthly_savings_rate":0}');
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4b] Rate 0: %', v; END IF;
  RAISE NOTICE 'PASS [1-4] Sparrate / Laufzeit / Monatsende / gedeckt / Rate 0';
END $$;

DO $$
DECLARE
  v_tg int; v_g int; r record;
BEGIN
  v_tg := (finance.fn_create_account('{"name":"__recalc_topf__","account_type":"cash","currency":"EUR","opening_balance":5000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at)
  VALUES ('__recalc_ziel__', 12000, current_date + 292, now() - interval '73 days') RETURNING id INTO v_g;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_tg, 'amount', 1500));
  SELECT * INTO r FROM finance.savings_goal_progress WHERE id = v_g;
  IF r.current_amount IS DISTINCT FROM 1500.00 OR r.expected_percent IS DISTINCT FROM 20.00
     OR r.progress_percent IS DISTINCT FROM 12.50 OR r.pace_drift_pp IS DISTINCT FROM 7.50
     OR r.behind_amount IS DISTINCT FROM 900.00 OR r.required_catchup_rate IS DISTINCT FROM 1050.00 THEN
    RAISE EXCEPTION 'FAIL [5] Fortschritt: current % expected % progress % drift % behind % catchup %',
      r.current_amount, r.expected_percent, r.progress_percent, r.pace_drift_pp, r.behind_amount, r.required_catchup_rate; END IF;
  RAISE NOTICE 'PASS [5] Sparziel-Fortschritt: Soll, Drift, Rueckstand, Nachhol-Rate';

  -- (5b) Glide Path: Umschicht-Fenster 60 Kalendermonate (Config-Default). Zieldatum genau 60 Monate voraus -> im
  --      Fenster; 61 Monate -> nicht; Zieldatum vorbei -> im Fenster (Geld wird jetzt gebraucht).
  UPDATE finance.savings_goals SET target_date = (date_trunc('month', current_date) + interval '60 months')::date WHERE id = v_g;
  IF finance.fn_goal_in_derisk_window(v_g) IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [5b] 60 Monate'; END IF;
  UPDATE finance.savings_goals SET target_date = (date_trunc('month', current_date) + interval '61 months')::date WHERE id = v_g;
  IF finance.fn_goal_in_derisk_window(v_g) IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5b] 61 Monate'; END IF;
  RAISE NOTICE 'PASS [5b] Glide-Path-Fenster 60/61 Monate';
END $$;

DO $$
DECLARE
  t date := current_date;
  v_giro int; v_tg int; v_rp int; v_res jsonb; v_s jsonb;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__recalc_giro__","account_type":"cash","currency":"EUR","opening_balance":4000}'::jsonb)->>'account_id')::int;
  v_tg   := (finance.fn_create_account('{"name":"__recalc_nr_tg__","account_type":"cash","currency":"EUR","opening_balance":3500}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_add_recurring_payment(v_giro, -950, '__recalc_miete__', 1::smallint, 'month', 1::smallint, t - 40, t - 40, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, -444, '__recalc_kfz__', 1::smallint, 'year', NULL, t - 100, t - 100, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, -12, '__recalc_verein__', 1::smallint, 'week', NULL, t - 20, t - 20, NULL, NULL, NULL);
  v_rp := finance.fn_add_recurring_payment(v_giro, -200, '__recalc_sparen__', 1::smallint, 'month', 1::smallint, t - 40, t - 40, NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_tg WHERE id = v_rp;

  v_res := finance.fn_create_savings_goal(jsonb_build_object('kind', 'emergency_reserve', 'target_months', 4,
             'reserve_account_id', v_tg, 'already_saved', 3000));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6 setup]: %', v_res; END IF;
  v_s := finance.fn_emergency_reserve_status();
  IF (v_s->'basis'->>'monthly_eur')::numeric IS DISTINCT FROM 1039.18
     OR (v_s->>'target_eur')::numeric IS DISTINCT FROM 4156.72
     OR v_s->'month_options' IS DISTINCT FROM '[{"months": 3, "eur": 3117.54}, {"months": 6, "eur": 6235.08}]'::jsonb
     OR (v_s->>'covered_eur')::numeric IS DISTINCT FROM 3000
     OR (v_s->>'gap_eur')::numeric IS DISTINCT FROM 1156.72
     OR v_s->>'state' IS DISTINCT FROM 'warn' THEN
    RAISE EXCEPTION 'FAIL [6] Notreserve: %', v_s; END IF;
  RAISE NOTICE 'PASS [6] Notreserve: Monatsbasis ohne Sparrate, 4 Monate, Optionen, Deckung, Luecke';
END $$;

ROLLBACK;

-- Sparrate zaehlt echte Abbuchungstermine bis einschliesslich Zieldatum: 15.02.2027 .. 15.08.2028 = 19 Raten.
BEGIN;
DO $$
DECLARE v jsonb;
BEGIN
  v := finance.fn_savings_rate_schedule('{"target_amount":12000,"already_saved":2000,"first_payment_date":"2027-02-15","target_date":"2028-08-31"}');
  IF (v->>'months')::int IS DISTINCT FROM 19 OR (v->>'monthly_rate')::numeric IS DISTINCT FROM 526.32 THEN
    RAISE EXCEPTION 'FAIL [P2 19 Raten]: %', v; END IF;
  -- Zieltag vor dem Abbuchungstag: Rate im Zielmonat faellt nicht mehr an (15.02.2027 .. 15.07.2028 = 18)
  v := finance.fn_savings_rate_schedule('{"target_amount":12000,"already_saved":2000,"first_payment_date":"2027-02-15","target_date":"2028-08-10"}');
  IF (v->>'months')::int IS DISTINCT FROM 18 THEN RAISE EXCEPTION 'FAIL [P2 18 Raten]: %', v; END IF;
  -- Monatsende: 31.01., 28.02., 31.03.2027 = 3 Termine
  v := finance.fn_savings_rate_schedule('{"target_amount":300,"first_payment_date":"2027-01-31","schedule_day_of_month":-1,"target_date":"2027-03-31"}');
  IF (v->>'months')::int IS DISTINCT FROM 3 OR (v->>'monthly_rate')::numeric IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL [P2 Monatsende]: %', v; END IF;
  -- kein Termin bis zum Ziel (erste Rate 10.01., Tag 15, Ziel 12.01.): ablehnen statt einer Rate, die nie abgeht
  v := finance.fn_savings_rate_schedule('{"target_amount":300,"first_payment_date":"2027-01-10","schedule_day_of_month":15,"target_date":"2027-01-12"}');
  IF (v->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [P2 kein Termin]: %', v; END IF;
  RAISE NOTICE 'PASS [P2 echte Termine, Monatsende, kein Termin -> ok:false]';
END $$;
ROLLBACK;
