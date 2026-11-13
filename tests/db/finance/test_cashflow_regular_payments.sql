-- tests/db/finance/test_cashflow_regular_payments.sql
-- Eine regelmaessige Zahlung zaehlt in der Monatsrechnung schon vor ihrem ersten Termin, wenn ihr Glied heute gilt
-- oder im Zyklus startet (siehe zaehlt/geplant), sonst meldete der Berater
-- Erfasstes als „nicht erfasst“. Invariante: die Rechnung zeigt, was regulaer laeuft, je Kette hoechstens einmal.
--   zaehlt   = heute gueltiges Glied, sonst das naechste aktive, wenn es innerhalb von fn_recurring_starts_within_cycle startet
--   geplant  = startet spaeter: zaehlt nicht, steht in finance.upcoming_recurring_payments (counted_in_cashflow = false)
--   Stichtag = finance.active_recurring_payments bleibt unveraendert „laeuft heute“
-- Self-contained, Werte erfunden. Jeder Block setzt per SAVEPOINT zurueck und vergleicht gegen den Stand davor.
BEGIN;

CREATE TEMP TABLE crp_ctx ON COMMIT DROP AS
SELECT (finance.fn_create_account('{"name":"__crp_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int AS giro,
       (finance.fn_create_account('{"name":"__crp_tg__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int AS tg;

CREATE FUNCTION pg_temp.rp(p_name text, p_amount numeric, p_unit text, p_interval int, p_from date,
                           p_to date DEFAULT NULL, p_status text DEFAULT 'active', p_pred int DEFAULT NULL,
                           p_target int DEFAULT NULL, p_account int DEFAULT NULL)
RETURNS int LANGUAGE sql AS $$
    INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                            first_payment_date, valid_from, valid_to, status, predecessor_id)
    SELECT p_name, COALESCE(p_account, c.giro), p_target, p_amount, p_interval, p_unit::finance.schedule_unit,
           p_from, p_from, p_to, p_status::finance.payment_status, p_pred
    FROM crp_ctx c
    RETURNING id;
$$;

SAVEPOINT crp;

-- ---------- [1-3] Rhythmus-Regel: Summen, starts_on, geplant ----------
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  b record; s record; r record;
BEGIN
  SELECT * INTO b FROM finance.monthly_cashflow_summary;
  PERFORM pg_temp.rp('__crp_running__', -1200, 'month', 1, t - 90);
  PERFORM pg_temp.rp('__crp_monthly_soon__', 250, 'month', 1, t + 10);
  PERFORM pg_temp.rp('__crp_yearly_later__', 1200, 'year', 1, t + 200);
  PERFORM pg_temp.rp('__crp_quarter_soon__', -30, 'month', 3, t + 15);
  PERFORM pg_temp.rp('__crp_quarter_far__', -300, 'month', 3, t + 120);
  PERFORM pg_temp.rp('__crp_monthly_far__', -100, 'month', 1, t + 60);

  SELECT * INTO s FROM finance.monthly_cashflow_summary;
  IF s.monthly_income - b.monthly_income IS DISTINCT FROM 350.00 THEN
    RAISE EXCEPTION 'FAIL [1 Einnahmen]: 250 monatlich + 1200 jaehrlich = 350, got %', s.monthly_income - b.monthly_income; END IF;
  IF s.monthly_obligations - b.monthly_obligations IS DISTINCT FROM -1210.00 THEN
    RAISE EXCEPTION 'FAIL [1 Ausgaben]: 1200 + 30 je Quartal = -1210, got %', s.monthly_obligations - b.monthly_obligations; END IF;
  IF s.monthly_free - b.monthly_free IS DISTINCT FROM -860.00 THEN
    RAISE EXCEPTION 'FAIL [1 frei]: 350 - 1210 = -860, got %', s.monthly_free - b.monthly_free; END IF;

  SELECT starts_on, monthly_equivalent_eur INTO r FROM finance.monthly_cashflow_overview WHERE name = '__crp_monthly_soon__';
  IF r.starts_on IS DISTINCT FROM t + 10 THEN RAISE EXCEPTION 'FAIL [2 starts_on]: %', r; END IF;
  IF (SELECT starts_on FROM finance.monthly_cashflow_overview WHERE name = '__crp_running__') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2 laufend]: starts_on muss NULL sein'; END IF;
  IF (SELECT monthly_equivalent_eur FROM finance.monthly_cashflow_overview WHERE name = '__crp_yearly_later__') IS DISTINCT FROM 100.00 THEN
    RAISE EXCEPTION 'FAIL [2 jaehrlich]: 1/12 erwartet'; END IF;

  -- geplant: nicht in der Rechnung, aber mit Startdatum sichtbar; gezaehlte Startende zeigt die View als counted
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE name IN ('__crp_quarter_far__', '__crp_monthly_far__')) THEN
    RAISE EXCEPTION 'FAIL [3]: Start ausserhalb des Fensters darf nicht zaehlen'; END IF;
  IF (SELECT counted_in_cashflow FROM finance.upcoming_recurring_payments WHERE name = '__crp_quarter_far__') IS DISTINCT FROM false
     OR (SELECT starts_on FROM finance.upcoming_recurring_payments WHERE name = '__crp_monthly_far__') IS DISTINCT FROM t + 60
     OR (SELECT counted_in_cashflow FROM finance.upcoming_recurring_payments WHERE name = '__crp_quarter_soon__') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [3 upcoming]: counted_in_cashflow / starts_on falsch'; END IF;
  IF EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE name = '__crp_running__') THEN
    RAISE EXCEPTION 'FAIL [3 upcoming]: Laufendes gehoert nicht hinein'; END IF;

  -- zwei Adressen, eine Regel: gezaehlte Startende und Zeilen mit starts_on sind dieselbe Menge
  IF EXISTS (SELECT id FROM finance.upcoming_recurring_payments WHERE counted_in_cashflow
             EXCEPT SELECT id FROM finance.recurring_cashflow_classified WHERE starts_on IS NOT NULL)
     OR EXISTS (SELECT id FROM finance.recurring_cashflow_classified WHERE starts_on IS NOT NULL
                EXCEPT SELECT id FROM finance.upcoming_recurring_payments WHERE counted_in_cashflow) THEN
    RAISE EXCEPTION 'FAIL [3 eine Regel]: upcoming.counted und classified.starts_on weichen ab'; END IF;

  -- [9] Stichtag bleibt: active_recurring_payments kennt keine Zukunft
  IF EXISTS (SELECT 1 FROM finance.active_recurring_payments WHERE valid_from > t) THEN
    RAISE EXCEPTION 'FAIL [9]: active_recurring_payments muss die Stichtags-Sicht bleiben'; END IF;
  RAISE NOTICE 'PASS [1-3, 9: Rhythmus-Regel, starts_on, geplant, Stichtag]';
END $$;
ROLLBACK TO SAVEPOINT crp;

-- ---------- [4-8] Ketten: nie doppelt, nie verschwunden ----------
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_b INT; b record; s record; v jsonb;
BEGIN
  SELECT * INTO b FROM finance.monthly_cashflow_summary;

  -- [4] Nachfolger: alt 100 laeuft bis +30, neu 120 ab +30 -> genau eine Zeile (die alte), kein Eintrag „geplant“
  v_a := pg_temp.rp('__crp_chain_old__', -100, 'month', 1, t - 60, t + 30);
  v_b := pg_temp.rp('__crp_chain_new__', -120, 'month', 1, t + 30, NULL, 'active', v_a);
  IF (SELECT count(*) FROM finance.monthly_cashflow_overview WHERE id IN (v_a, v_b)) <> 1
     OR NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_a AND starts_on IS NULL) THEN
    RAISE EXCEPTION 'FAIL [4 Nachfolger]: genau das laufende Glied erwartet'; END IF;
  IF EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id IN (v_a, v_b)) THEN
    RAISE EXCEPTION 'FAIL [4 Nachfolger]: eine geplante Aenderung ist keine neue Zahlung'; END IF;
  SELECT * INTO s FROM finance.monthly_cashflow_summary;
  IF s.monthly_obligations - b.monthly_obligations IS DISTINCT FROM -100.00 THEN
    RAISE EXCEPTION 'FAIL [4 Summe]: -100 erwartet, got %', s.monthly_obligations - b.monthly_obligations; END IF;

  -- [5] Luecke: Vorgaenger beendet, Folgeglied im Fenster zaehlt einmal, ausserhalb steht es unter „geplant“
  v_a := pg_temp.rp('__crp_gap_old__', -40, 'month', 1, t - 90, t - 10);
  v_b := pg_temp.rp('__crp_gap_new__', -50, 'month', 1, t + 10, NULL, 'active', v_a);
  IF (SELECT count(*) FROM finance.monthly_cashflow_overview WHERE id IN (v_a, v_b)) <> 1
     OR NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_b AND starts_on = t + 10) THEN
    RAISE EXCEPTION 'FAIL [5 Luecke im Fenster]: Folgeglied erwartet'; END IF;
  v_a := pg_temp.rp('__crp_gapfar_old__', -41, 'month', 1, t - 90, t - 10);
  v_b := pg_temp.rp('__crp_gapfar_new__', -51, 'month', 1, t + 60, NULL, 'active', v_a);
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id IN (v_a, v_b))
     OR NOT EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id = v_b AND NOT counted_in_cashflow) THEN
    RAISE EXCEPTION 'FAIL [5 Luecke weit]: nicht zaehlen, aber geplant'; END IF;

  -- [6] Pausiert und beendet zaehlen nie
  v_a := pg_temp.rp('__crp_paused__', -60, 'month', 1, t - 30, NULL, 'paused');
  v_b := pg_temp.rp('__crp_paused_future__', -61, 'month', 1, t + 5, NULL, 'paused');
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id IN (v_a, v_b))
     OR EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id IN (v_a, v_b)) THEN
    RAISE EXCEPTION 'FAIL [6 pausiert]'; END IF;
  v_a := pg_temp.rp('__crp_ended__', -62, 'month', 1, t - 90, t - 5);
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_a) THEN RAISE EXCEPTION 'FAIL [6 beendet]'; END IF;

  -- [7] Pausiert mit aktivem Nachfolger: „laeuft wieder ab …“ ist die massgebliche Zeile
  v_a := pg_temp.rp('__crp_resume_old__', -70, 'month', 1, t - 30, t + 10, 'paused');
  v_b := pg_temp.rp('__crp_resume_new__', -71, 'month', 1, t + 10, NULL, 'active', v_a);
  IF NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_b AND starts_on = t + 10)
     OR EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_a) THEN
    RAISE EXCEPTION 'FAIL [7 im Fenster]: aktiver Nachfolger zaehlt, pausiertes Glied nicht'; END IF;
  v_a := pg_temp.rp('__crp_resumefar_old__', -72, 'month', 1, t - 30, t + 60, 'paused');
  v_b := pg_temp.rp('__crp_resumefar_new__', -73, 'month', 1, t + 60, NULL, 'active', v_a);
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id IN (v_a, v_b))
     OR NOT EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id = v_b AND NOT counted_in_cashflow) THEN
    RAISE EXCEPTION 'FAIL [7 weit]: aktiver Nachfolger steht unter „geplant“'; END IF;

  -- [8] Leere Glieder [d,d) (entstehen beim Schliessen einer Kette mit geplanter Aenderung) sind nie massgeblich
  v_a := pg_temp.rp('__crp_empty_old__', -80, 'month', 1, t - 30, t + 20);
  v_b := pg_temp.rp('__crp_empty_new__', -81, 'month', 1, t + 20, t + 20, 'active', v_a);
  IF EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id = v_b)
     OR EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_b) THEN
    RAISE EXCEPTION 'FAIL [8 leer aktiv]: leeres Glied zaehlt nie'; END IF;
  v_a := pg_temp.rp('__crp_emptyonly__', -82, 'month', 1, t + 20, t + 20);
  IF EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id = v_a)
     OR EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_a) THEN
    RAISE EXCEPTION 'FAIL [8 nur leer]: leere Kette zaehlt nie'; END IF;
  v := finance.fn_recurring_name_check('__crp_emptyonly__');
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [8 Namenssperre]: leeres Glied sperrt keinen Namen: %', v; END IF;
  -- auch die uebrigen Leser der Ketten-Auswahl: kein Geister-Fluss, kein Geister-Dauerauftrag
  v_a := pg_temp.rp('__crp_emptyorder__', -85, 'month', 1, t + 20, t + 20, 'active', NULL, (SELECT tg FROM crp_ctx));
  IF EXISTS (SELECT 1 FROM finance.fn_account_flows((SELECT giro FROM crp_ctx)) f WHERE f.rp_id = v_a)
     OR EXISTS (SELECT 1 FROM finance.fn_standing_orders() o WHERE o.rp_id = v_a) THEN
    RAISE EXCEPTION 'FAIL [8 Leser]: leeres Glied darf weder Fluss noch Dauerauftrag sein'; END IF;
  -- Reopen mit demselben valid_from wie das leere Glied: die reaktivierte Zeile ist massgeblich
  v_a := pg_temp.rp('__crp_reopen_empty__', -83, 'month', 1, t + 15, t + 15, 'paused');
  v_b := pg_temp.rp('__crp_reopen_new__', -84, 'month', 1, t + 15, NULL, 'active', v_a);
  IF NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_b AND starts_on = t + 15) THEN
    RAISE EXCEPTION 'FAIL [8 Reopen]: reaktivierte Zeile muss zaehlen'; END IF;

  RAISE NOTICE 'PASS [4-8: Nachfolger, Luecke, pausiert, beendet, leere Glieder]';
END $$;
ROLLBACK TO SAVEPOINT crp;

-- ---------- [10-11, 14] Klassen und Bereiche ----------
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_kid INT; v_rp INT; v_loan INT; v_depot INT; c record;
  v_giro INT := (SELECT giro FROM crp_ctx);
  v_tg   INT := (SELECT tg FROM crp_ctx);
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__crp_kid__', 'Kind Beispiel', 'child');
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__crp_kid_acct__', 'cash', 'EUR', 'active', '__crp_kid__') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__crp_depot__', 'stocks_depot', 'EUR', 'active', v_tg) RETURNING id INTO v_depot;

  -- [10] Kreditrate startet in 10 Tagen: Zins = Konsum, Rest = Tilgung (60.000 bei 6 % = 300 Zins bei Rate 500)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__crp_loan_acct__', 'loan', 'EUR', 'active') RETURNING id INTO v_loan;
  UPDATE finance.account_balances SET balance = -60000 WHERE account_id = v_loan;
  v_rp := pg_temp.rp('__crp_loan_rate__', -500, 'month', 1, t + 10);
  INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate, loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__crp_loan__', 60000, t, 6, v_loan, v_giro, v_rp);
  SELECT cashflow_class, consumption_eur, principal_eur INTO c FROM finance.monthly_cashflow_overview WHERE id = v_rp;
  IF c.cashflow_class IS DISTINCT FROM 'loan' OR c.consumption_eur IS DISTINCT FROM -300.00 OR c.principal_eur IS DISTINCT FROM -200.00 THEN
    RAISE EXCEPTION 'FAIL [10 Kredit]: %', c; END IF;

  -- [10] Kind-Konto: Familie ja, Eltern-Blick nein; starts_on steht in beiden Blicken
  v_rp := pg_temp.rp('__crp_kid_income__', 25, 'month', 1, t + 10, NULL, 'active', NULL, NULL, v_kid);
  IF NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_rp)
     OR EXISTS (SELECT 1 FROM finance.parent_cashflow_overview WHERE id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [10 Kind]: nur im Familien-Blick'; END IF;
  v_rp := pg_temp.rp('__crp_parent_soon__', -15, 'month', 1, t + 10);
  IF (SELECT starts_on FROM finance.parent_cashflow_overview WHERE id = v_rp) IS DISTINCT FROM t + 10 THEN
    RAISE EXCEPTION 'FAIL [10 Eltern]: starts_on fehlt im Eltern-Blick'; END IF;

  -- [11] Eigener Uebertrag in Zukunft bleibt neutral, steht aber unter „kommt“
  v_rp := pg_temp.rp('__crp_own_transfer__', -900, 'month', 1, t + 10, NULL, 'active', NULL, v_tg);
  IF (SELECT cashflow_class FROM finance.recurring_cashflow_classified WHERE id = v_rp) IS DISTINCT FROM 'transfer'
     OR EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_rp)
     OR NOT EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [11 Uebertrag]'; END IF;

  -- [14] Gegenfinanzierung nur aus gezaehlten Zeilen: Sparrate in den Topf startet ausserhalb -> Sparplan vom Topf bleibt
  -- echtes Sparen; rueckt sie ins Fenster, ist er gegenfinanziert (ein zweiter Topf, damit beide Faelle nebeneinander stehen)
  v_rp := pg_temp.rp('__crp_far_rate__', -100, 'month', 1, t + 60, NULL, 'active', NULL, v_tg);
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id)
    VALUES ('__crp_far_goal__', 1000, t + 700, 'active', v_rp);
  v_rp := pg_temp.rp('__crp_plan_from_pot__', -100, 'month', 1, t - 30, NULL, 'active', NULL, NULL, v_tg);
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__crp_plan__', v_depot, 'CRP1', 'Beispiel ETF', v_rp);
  SELECT cashflow_class, saving_eur INTO c FROM finance.monthly_cashflow_overview WHERE id = v_rp;
  IF c.cashflow_class IS DISTINCT FROM 'saving' OR c.saving_eur IS DISTINCT FROM -100.00 THEN
    RAISE EXCEPTION 'FAIL [14 weit]: Rate zaehlt noch nicht, Sparplan bleibt Sparen: %', c; END IF;
  UPDATE finance.recurring_payments SET valid_from = t + 10, first_payment_date = t + 10 WHERE name = '__crp_far_rate__';
  SELECT cashflow_class, saving_eur INTO c FROM finance.monthly_cashflow_overview WHERE id = v_rp;
  IF c.cashflow_class IS DISTINCT FROM 'saving_internal' OR c.saving_eur IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [14 im Fenster]: Rate zaehlt, Sparplan ist gegenfinanziert: %', c; END IF;

  RAISE NOTICE 'PASS [10, 11, 14: Kredit, Kind, Eltern, Uebertrag, Gegenfinanzierung]';
END $$;
ROLLBACK TO SAVEPOINT crp;

-- ---------- [12-13] Leser: Reife des Finanzplans, Pflicht-Basis, Notreserve ----------
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v jsonb; v_before numeric; v_status_before numeric; v_status_after numeric;
BEGIN
  -- [12] nur eine Einnahme ausserhalb des Fensters -> weiter „fehlt“; im Fenster -> vorhanden (Bestand pausiert, damit die
  -- Pruefung unabhaengig vom Stand der Test-DB greift; SAVEPOINT raeumt)
  UPDATE finance.recurring_payments SET status = 'paused';
  PERFORM pg_temp.rp('__crp_income_far__', 500, 'month', 1, t + 60);
  v := finance.fn_plan_readiness('finance', NULL);
  IF NOT v->'missing' @> '[{"key":"income"}]'::jsonb THEN RAISE EXCEPTION 'FAIL [12 weit]: %', v; END IF;
  PERFORM pg_temp.rp('__crp_income_soon__', 500, 'month', 1, t + 10);
  v := finance.fn_plan_readiness('finance', NULL);
  IF v->'missing' @> '[{"key":"income"}]'::jsonb THEN RAISE EXCEPTION 'FAIL [12 im Fenster]: %', v; END IF;

  -- [13] startende Ausgabe zaehlt in Pflicht-Basis und Notreserve-Basis, spaeter startende nicht
  v_before := (finance.fn_liquidity_snapshot()->>'fixed_expenses_eur')::numeric;
  v_status_before := (finance.fn_emergency_reserve_status()->'basis'->>'monthly_eur')::numeric;
  PERFORM pg_temp.rp('__crp_duty_far__', -75, 'month', 1, t + 60);
  IF (finance.fn_liquidity_snapshot()->>'fixed_expenses_eur')::numeric IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'FAIL [13 weit]: spaeter Start zaehlt nicht in der Pflicht-Basis'; END IF;
  PERFORM pg_temp.rp('__crp_duty_soon__', -75, 'month', 1, t + 10);
  IF (finance.fn_liquidity_snapshot()->>'fixed_expenses_eur')::numeric - v_before IS DISTINCT FROM 75.00 THEN
    RAISE EXCEPTION 'FAIL [13 Snapshot]: +75 erwartet'; END IF;
  v_status_after := (finance.fn_emergency_reserve_status()->'basis'->>'monthly_eur')::numeric;
  IF v_status_after - v_status_before IS DISTINCT FROM 75.00 THEN
    RAISE EXCEPTION 'FAIL [13 Notreserve]: Basis +75 erwartet, got %', v_status_after - v_status_before; END IF;
  RAISE NOTICE 'PASS [12-13: Plan-Reife, Pflicht-Basis, Notreserve-Basis]';
END $$;
ROLLBACK TO SAVEPOINT crp;

-- ---------- [17] Pausieren gilt fuer die Zahlung: ein geplanter Nachfolger lebt nicht weiter, Fortsetzen holt ihn zurueck ----------
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_old INT; v_new INT; v_r jsonb;
BEGIN
  v_old := pg_temp.rp('__crp_pause_old__', -90, 'month', 1, t - 30, t + 10);
  v_new := pg_temp.rp('__crp_pause_new__', -95, 'month', 1, t + 10, NULL, 'active', v_old);
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_old, 'status', 'paused'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [17 Setup]: %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id IN (v_old, v_new))
     OR EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id IN (v_old, v_new)) THEN
    RAISE EXCEPTION 'FAIL [17 Pause]: pausierte Zahlung zaehlt nicht ueber ihren Nachfolger'; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_old, 'status', 'active'));
  IF NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_old AND starts_on IS NULL)
     OR (SELECT status FROM finance.recurring_payments WHERE id = v_new) IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL [17 Fortsetzen]: Glied und Nachfolger wieder aktiv'; END IF;
  -- Pausieren ueber den Kopf der Kette erfasst auch das laufende Glied
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_new, 'status', 'paused'));
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id IN (v_old, v_new)) THEN
    RAISE EXCEPTION 'FAIL [17 Kopf]: Pause ueber den Kopf muss das laufende Glied mitnehmen'; END IF;
  -- Fortsetzen des spaeteren Glieds laesst das fruehere pausiert („laeuft wieder ab ...“)
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_new, 'status', 'active'));
  IF (SELECT status FROM finance.recurring_payments WHERE id = v_old) IS DISTINCT FROM 'paused'
     OR NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE id = v_new AND starts_on = t + 10) THEN
    RAISE EXCEPTION 'FAIL [17 ab spaeter]: nur das spaetere Glied laeuft wieder'; END IF;
  RAISE NOTICE 'PASS [17: Pausieren und Fortsetzen gelten fuer die Kette]';
END $$;
ROLLBACK TO SAVEPOINT crp;

-- ---------- [15] Bekannte Grenze: Abloesung als zwei getrennte Ketten zaehlt im Uebergang doppelt ----------
-- Die Datenbank kann ohne predecessor_id nicht wissen, dass die eine Zahlung die andere ersetzt. Der Berater hat dafuer eine
-- Regel (last_valid_day neben starts_on: nachfragen). Faellt dieser Test, ist die Grenze behoben: Berater-Regel mit anpassen.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  b numeric; a numeric;
BEGIN
  SELECT monthly_income INTO b FROM finance.monthly_cashflow_summary;
  PERFORM pg_temp.rp('__crp_salary_old__', 2000, 'month', 1, t - 200, t + 20);
  PERFORM pg_temp.rp('__crp_salary_new__', 2100, 'month', 1, t + 20);
  SELECT monthly_income INTO a FROM finance.monthly_cashflow_summary;
  IF a - b IS DISTINCT FROM 4100.00 THEN RAISE EXCEPTION 'FAIL [15 Grenze]: beide zaehlen im Uebergang, got %', a - b; END IF;
  IF (SELECT last_valid_day FROM finance.monthly_cashflow_overview WHERE name = '__crp_salary_old__') IS DISTINCT FROM t + 19
     OR (SELECT starts_on FROM finance.monthly_cashflow_overview WHERE name = '__crp_salary_new__') IS DISTINCT FROM t + 20 THEN
    RAISE EXCEPTION 'FAIL [15 sichtbar]: last_valid_day und starts_on muessen das Paar zeigen'; END IF;
  RAISE NOTICE 'PASS [15: Grenze festgeschrieben, Paar ist in den Zeilen erkennbar]';
END $$;
ROLLBACK TO SAVEPOINT crp;

-- ---------- [16] Sofort-Hinweis beim Anlegen: im Fenster sofort, spaeter erst der Cron ----------
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_r jsonb;
  v_giro INT := (SELECT giro FROM crp_ctx);
BEGIN
  PERFORM core.fn_notify_resolve('finance', 'cashflow_coverage');
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name', '__crp_fold_far__', 'account_id', v_giro,
           'direction', 'expense', 'amount', 900000, 'schedule_unit', 'month', 'first_payment_date', to_char(t + 60, 'YYYY-MM-DD')));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r ? 'cashflow_coverage' THEN
    RAISE EXCEPTION 'FAIL [16 weit]: kein Sofort-Hinweis erwartet: %', v_r; END IF;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name', '__crp_fold_soon__', 'account_id', v_giro,
           'direction', 'expense', 'amount', 900000, 'schedule_unit', 'month', 'first_payment_date', to_char(t + 10, 'YYYY-MM-DD')));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR NOT v_r ? 'cashflow_coverage' THEN
    RAISE EXCEPTION 'FAIL [16 im Fenster]: Sofort-Hinweis erwartet: %', v_r; END IF;
  RAISE NOTICE 'PASS [16: Sofort-Hinweis folgt der Regel]';
END $$;
ROLLBACK TO SAVEPOINT crp;

ROLLBACK;
