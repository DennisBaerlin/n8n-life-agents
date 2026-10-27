-- tests/db/finance/test_savings_goal_progress.sql
-- WS-A (Phase S): finance.savings_goal_progress.current_amount = aktuelle RESERVE = vorzeichen-rohe Summe
-- ALLER mit dem Ziel markierten Buchungen (transactions.savings_goal_id), ueber BELIEBIG viele Konten.
-- Reserve-Zufluss +, Entnahme/Abfluss - => Entnahme SENKT den Fortschritt (Kern-Regressionsfall, der den
-- frueheren Raten-Zaehler als latenten Fehler entlarvt hat). Erkenntnis-Fakten (expected/pace/projected/
-- catchup) unveraendert aus current_amount + Daten. Erzeuger-Pfad: create mit Reserve-Topf -> Rate ist
-- Transfer -> fn_book_recurring_transfer stempelt savings_goal_id NUR aufs Haben-(Reserve-)Bein.
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_giro INT; v_topf1 INT; v_topf2 INT;
  v_gA INT; v_gB INT; v_gC INT; v_gD INT; v_gE INT; v_rpE INT;
  v_cur NUMERIC; v_rem NUMERIC; v_prog NUMERIC; v_exp NUMERIC; v_drift NUMERIC;
  v_proj DATE; v_catch NUMERIC; v_tdate DATE; v_created DATE;
  v_total NUMERIC; v_elapsed NUMERIC; v_exp_calc NUMERIC; v_months_to INT; v_cnt INT;
  v_settle INT; v_depot INT; v_gF INT; v_gG INT; v_obs NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__sgp3_giro__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;   v_giro  := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgp3_topf1__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;  v_topf1 := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgp3_topf2__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;  v_topf2 := (v_res->>'account_id')::int;

  -- ===================================================================================
  -- Ziel A: Reserve ueber ZWEI Konten verteilt (+300 Topf1, +400 Topf2) + eine ENTNAHME (-100 Topf1)
  --   + eine NICHT markierte Buchung (+999, kein Tag) -> ausgeschlossen.  -> current = 600.
  -- created vor 180 T, Zieldatum +180 T, Ziel 2000 -> progress 30 %, expected ~50 % (hinter Plan).
  -- ===================================================================================
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at)
    VALUES ('__sgp3_gA__', 2000, current_date + 180, 'active', (current_date - 180)::timestamptz) RETURNING id INTO v_gA;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_topf1,  300, current_date - 150, 'transfer', v_gA, gen_random_uuid()),   -- Reserve-Zufluss (Konto 1)
    (v_topf2,  400, current_date - 120, 'transfer', v_gA, gen_random_uuid()),   -- Reserve-Zufluss (Konto 2 -> Multi-Konto)
    (v_topf1, -100, current_date -  60, 'transfer', v_gA, gen_random_uuid()),   -- ENTNAHME -> senkt den Fortschritt
    (v_topf1,  999, current_date -  30, 'other',    NULL, NULL);   -- nicht markiert -> ausgeschlossen

  SELECT current_amount, remaining_amount, progress_percent, expected_percent, pace_drift_pp,
         projected_completion_date, required_catchup_rate, target_date
    INTO v_cur, v_rem, v_prog, v_exp, v_drift, v_proj, v_catch, v_tdate
  FROM finance.savings_goal_progress WHERE id = v_gA;

  IF v_cur IS DISTINCT FROM 600 THEN
    RAISE EXCEPTION 'FAIL [A current]: erwartet 600 (300+400-100, Multi-Konto, Entnahme senkt, untagged aus), got %', v_cur; END IF;
  IF v_prog IS DISTINCT FROM 30.00 THEN RAISE EXCEPTION 'FAIL [A progress]: erwartet 30.00, got %', v_prog; END IF;
  RAISE NOTICE 'PASS [A: Reserve 600 ueber 2 Konten, Entnahme -100 gesenkt, untagged ausgeschlossen -> 30%%]';

  v_created := current_date - 180; v_total := (v_tdate - v_created)::numeric; v_elapsed := (current_date - v_created)::numeric;
  v_exp_calc := round(LEAST(GREATEST(v_elapsed/v_total, 0), 1) * 100, 2);
  IF v_exp IS DISTINCT FROM v_exp_calc THEN RAISE EXCEPTION 'FAIL [A expected_percent]: erwartet %, got %', v_exp_calc, v_exp; END IF;
  IF v_drift IS DISTINCT FROM round(v_exp_calc - 30.00, 2) THEN RAISE EXCEPTION 'FAIL [A pace_drift]: erwartet %, got %', round(v_exp_calc - 30.00, 2), v_drift; END IF;
  v_months_to := GREATEST(1, CEIL((v_tdate - current_date) / finance.fn_days_per_month())::int);
  IF v_catch IS DISTINCT FROM round(1400.0 / v_months_to, 2) THEN RAISE EXCEPTION 'FAIL [A catchup]: erwartet %, got %', round(1400.0 / v_months_to, 2), v_catch; END IF;
  IF v_proj IS NULL OR v_proj <= current_date THEN RAISE EXCEPTION 'FAIL [A projected]: erwartet Zukunftsdatum, got %', v_proj; END IF;
  RAISE NOTICE 'PASS [A: Erkenntnis-Fakten expected=% drift=% catchup=% projected=%]', v_exp, v_drift, v_catch, v_proj;

  -- ===================================================================================
  -- Ziel B (EXPLIZIT Entnahme-senkt): +500 Zufluss, dann -300 Entnahme -> current = 200.
  -- ===================================================================================
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__sgp3_gB__', 1000, current_date + 365, 'active') RETURNING id INTO v_gB;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_topf1,  500, current_date - 40, 'transfer', v_gB, gen_random_uuid()),
    (v_topf1, -300, current_date - 10, 'transfer', v_gB, gen_random_uuid());   -- "Erspartes anderweitig gebraucht"
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_gB;
  IF v_cur IS DISTINCT FROM 200 THEN RAISE EXCEPTION 'FAIL [B Entnahme-senkt]: erwartet 200 (500-300), got %', v_cur; END IF;
  RAISE NOTICE 'PASS [B: Entnahme senkt den Fortschritt (500-300=200) — der Kern-Regressionsfall]';

  -- ===================================================================================
  -- Ziel C: keine markierte Buchung -> current = 0 (Defensiv-Zweig).
  -- ===================================================================================
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__sgp3_gC__', 500, current_date + 365, 'active') RETURNING id INTO v_gC;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_gC;
  IF v_cur IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [C kein Tag]: erwartet 0, got %', v_cur; END IF;
  RAISE NOTICE 'PASS [C: keine markierte Reserve-Bewegung -> current 0]';

  -- ===================================================================================
  -- Ziel D (uebererfuellt): Ziel 100, +500 -> remaining -400 -> projected/catchup NULL (kein Div0/Negativ).
  -- ===================================================================================
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__sgp3_gD__', 100, current_date + 200, 'active') RETURNING id INTO v_gD;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_topf1, 500, current_date - 5, 'transfer', v_gD, gen_random_uuid());
  SELECT current_amount, remaining_amount, projected_completion_date, required_catchup_rate
    INTO v_cur, v_rem, v_proj, v_catch FROM finance.savings_goal_progress WHERE id = v_gD;
  IF v_cur IS DISTINCT FROM 500 OR v_rem IS DISTINCT FROM -400 THEN RAISE EXCEPTION 'FAIL [D]: current=%, remaining=%', v_cur, v_rem; END IF;
  IF v_proj IS NOT NULL OR v_catch IS NOT NULL THEN RAISE EXCEPTION 'FAIL [D]: projected/catchup muessen NULL sein (gedeckt), got %/%', v_proj, v_catch; END IF;
  RAISE NOTICE 'PASS [D: uebererfuellt -> projected/catchup NULL]';

  -- ===================================================================================
  -- Ziel E (ERZEUGER-PFAD): create mit Reserve-Topf -> Rate ist Transfer; book stempelt NUR das Haben-Bein.
  -- ===================================================================================
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__sgp3_gE__','target_amount',1200,'monthly_savings_rate',100,
    'account_id',v_giro,'reserve_account_id',v_topf1,'schedule_day_of_month',1,'first_payment_date',(current_date - 30)::text)) INTO v_res;
  v_gE := (v_res->>'goal_id')::int; v_rpE := (v_res->>'recurring_payment_id')::int;
  IF v_res ? 'reserve_account_id' THEN RAISE EXCEPTION 'FAIL [E return]: reserve_account_id ist Input-Echo und gehoert nicht in den Return (=%)', v_res; END IF;
  IF (SELECT target_account_id FROM finance.recurring_payments WHERE id = v_rpE) IS DISTINCT FROM v_topf1 THEN
    RAISE EXCEPTION 'FAIL [E target]: Rate ist kein Transfer in den Reserve-Topf'; END IF;
  -- ein Vorkommen buchen (delegiert an fn_book_recurring_transfer)
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rpE, 'due_date', (current_date - 30)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [E book]: %', v_res; END IF;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_gE;
  IF v_cur IS DISTINCT FROM 100 THEN RAISE EXCEPTION 'FAIL [E progress]: erwartet 100 (gebuchter Reserve-Zufluss), got %', v_cur; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE savings_goal_id = v_gE;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [E tag]: erwartet GENAU 1 getaggtes Bein (Haben), got % (beide Beine getaggt = Netto-0-Bug)', v_cnt; END IF;
  RAISE NOTICE 'PASS [E: create+Reserve -> Transfer-Rate; book stempelt nur das Haben-Bein -> progress 100]';

  -- ===================================================================================
  -- Ziel F (WS-B Reserve-Journal): Cash-Tag +300 PLUS Depot-Anteil = Σ savings_goal_reserve_entries.delta_native.
  --   Zwei APPEND-Zeilen (+600, +100) -> Depot-Reserve 700. current = 300 (Cash) + 700 (Journal) = 1000.
  --   Der MARKTWERT zaehlt NICHT in den Fortschritt (nur Deckung, depot_reserve_status) -> Kurs-Explosion
  --   blaeht current_amount nicht auf (Owner-Einwand, WS-B). Dann CASCADE-Probe (Ziel-DELETE -> Journal weg).
  -- ===================================================================================
  SELECT finance.fn_create_account('{"name":"__sgp3_settle__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_settle := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object('name','__sgp3_depot__','account_type','stocks_depot','settlement_id',v_settle,'account_holder','Test')) INTO v_res; v_depot := (v_res->>'account_id')::int;

  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__sgp3_gF__', 5000, current_date + 365, 'active') RETURNING id INTO v_gF;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_topf1, 300, current_date - 10, 'transfer', v_gF, gen_random_uuid());   -- Cash-Term
  -- Depot-Anteil als append-only Journal (zwei Zeilen, Σ 700) — die fn rechnet den delta sonst; hier direkt fuer den View-Term.
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
    VALUES (v_gF, v_depot, 600, 'manual'), (v_gF, v_depot, 100, 'manual');

  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_gF;
  IF v_cur IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL [F current]: erwartet 1000 (300 Cash + 700 Depot-Journal), got %', v_cur; END IF;
  RAISE NOTICE 'PASS [F: Cash 300 + Depot-Reserve-Journal 700 (Σ delta_native) -> 1000, Marktwert irrelevant fuer Fortschritt]';

  -- CASCADE: Ziel loeschen -> alle savings_goal_reserve_entries-Zeilen fallen mit (Reserve-Zuordnung weg, Bestand bleibt)
  DELETE FROM finance.savings_goals WHERE id = v_gF;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_gF;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [F cascade-goal]: erwartet 0 Journal-Zeilen nach Ziel-DELETE, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [F: DELETE Ziel -> savings_goal_reserve_entries cascadet (0 Zeilen)]';

  -- ===================================================================================
  -- Ziel G (NEGATIVER Reserve-Stand, Cold-Eyes A#4/A#6): +100 Zufluss, dann -300 Entnahme -> saved = -200.
  --   current_amount darf NEGATIV werden (Reserve-Modell), aber observed_monthly_rate MUSS NULL sein
  --   (kein negatives "Spartempo" -> saved>0-Guard, analog projected_completion_date).
  -- ===================================================================================
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at)
    VALUES ('__sgp3_gG__', 1000, current_date + 365, 'active', (current_date - 60)::timestamptz) RETURNING id INTO v_gG;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_topf1,  100, current_date - 40, 'transfer', v_gG, gen_random_uuid()),
    (v_topf1, -300, current_date - 10, 'transfer', v_gG, gen_random_uuid());   -- Netto-Entnahme uebersteigt Einzahlung
  SELECT current_amount, observed_monthly_rate INTO v_cur, v_obs FROM finance.savings_goal_progress WHERE id = v_gG;
  IF v_cur IS DISTINCT FROM -200 THEN RAISE EXCEPTION 'FAIL [G current]: erwartet -200 (100-300, Reserve darf negativ), got %', v_cur; END IF;
  IF v_obs IS NOT NULL THEN RAISE EXCEPTION 'FAIL [G observed_monthly_rate]: erwartet NULL bei saved<0 (kein negatives Spartempo), got %', v_obs; END IF;
  RAISE NOTICE 'PASS [G: negativer Reserve-Stand -200 -> observed_monthly_rate NULL (kein negatives Tempo)]';
END $$;

-- (H) Hand-Zuordnung ist kein Spartempo (Sparziel-Zweckbindung 2026-10-27): Ziel 6000 seit 2 Monaten, 2000 als
--     Startbestand zugeordnet + 400 gespart (getaggt) -> current 2400, observed_monthly_rate = 400/2 = 200 (nicht 1200),
--     projected aus dem Tempo 200. Nur Zuordnung -> observed NULL (kein Tempo).
DO $$
DECLARE v_p2p int; v_g int; v_g2 int; v_cur numeric; v_obs numeric; v_proj date;
BEGIN
  v_p2p := (finance.fn_create_account('{"name":"__sgp_h_p2p__","account_type":"p2p","opening_balance":8000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at)
    VALUES ('__sgp_h__', 6000, current_date + 600, 'active', now() - interval '60 days') RETURNING id INTO v_g;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_p2p, 'amount', 2000));
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_p2p, 400, current_date - 5, 'transfer', v_g, gen_random_uuid());
  SELECT current_amount, observed_monthly_rate, projected_completion_date INTO v_cur, v_obs, v_proj
    FROM finance.savings_goal_progress WHERE id = v_g;
  IF v_cur IS DISTINCT FROM 2400 OR v_obs IS DISTINCT FROM 200.00
     OR v_proj IS DISTINCT FROM (current_date + (round(3600 / 200.0 * finance.fn_days_per_month())::int))::date THEN
    RAISE EXCEPTION 'FAIL [H Tempo ohne Zuordnung]: cur % obs % proj %', v_cur, v_obs, v_proj; END IF;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at)
    VALUES ('__sgp_h2__', 6000, current_date + 600, 'active', now() - interval '60 days') RETURNING id INTO v_g2;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g2, 'account_id', v_p2p, 'amount', 1000));
  IF (SELECT observed_monthly_rate FROM finance.savings_goal_progress WHERE id = v_g2) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [H nur Zuordnung -> kein Tempo]'; END IF;
  -- (H3) Zuordnung UNTER schon eingezahltes Geld gesenkt (manual netto negativ): Tempo nicht hoeher als der Stand,
  --      earmarked_amount nie negativ (Code-Review 2026-10-27)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_p2p, 1200, current_date - 5, 'transfer', v_g2, gen_random_uuid());
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g2, 'account_id', v_p2p, 'amount', 1000));
  IF (SELECT current_amount FROM finance.savings_goal_progress WHERE id = v_g2) IS DISTINCT FROM 1000
     OR (SELECT observed_monthly_rate FROM finance.savings_goal_progress WHERE id = v_g2) IS DISTINCT FROM 500.00
     OR (SELECT earmarked_amount FROM finance.savings_goal_progress WHERE id = v_g2) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [H3 negative Zuordnung]: %', (SELECT row_to_json(p) FROM finance.savings_goal_progress p WHERE id = v_g2); END IF;
  RAISE NOTICE 'PASS [H: Hand-Zuordnung zaehlt zum Stand, nicht zum Spartempo; negative Zuordnung kein Tempo]';
END $$;

ROLLBACK;
