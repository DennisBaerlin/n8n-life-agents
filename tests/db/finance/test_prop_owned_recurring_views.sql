-- tests/db/finance/test_prop_owned_recurring_views.sql
-- Eigenschafts-Test: Beitraege/Raten, die einem Vertrag gehoeren (Versicherung, Vorsorge, Sparplan), in allen lesenden
-- Sichten und nach einer Aenderung.
--   V1 Monats-Normalisierung: derselbe Vertrag zeigt in Vertrags-View (active_insurances, pension_overview,
--      savings_plan_overview), Monatsrechnung (monthly_cashflow_overview) und Konto-Sicht (fn_account_flows) denselben
--      Monatswert, mit gleichem Vorzeichen (Ausgabe negativ); der Jahresbeitrag ist Betrag x Termine eines Jahres
--   V2 Post-State: die Rueckgabe der Write-fn nennt dieselben Zahlen wie die View danach
--   V3 Beitrags-Wechsel zu einem Stichtag: Termine der Kette unveraendert, Betrag wechselt genau am Stichtag
--   V4 Vertragsende: kein Termin nach dem genannten letzten Tag; die View nennt diesen Tag
--   V5 Sparplan: naechste Ausfuehrung der Uebersicht = fruehester offener Termin der Kette, vor und nach einer
--      geplanten Betrags-Aenderung
--   V6 Vertrag vor dem Start mit geplanter Aenderung: alle Sichten zeigen den Start-Betrag (fn_recurring_current)
--   V7 eine Aenderung zum Stichtag der geplanten Aenderung vergleicht mit dem Glied, das an dem Stichtag gilt
-- Start der Zahlungen 40 Tage vor heute (die Views lesen current_date; ein laufender Vertrag hat ein heute gueltiges
-- Glied); jeder Fall in einem eigenen Savepoint.
BEGIN;

DO $$
DECLARE
  v_t DATE := current_date;
  v_first DATE := current_date - 40;   -- laufender Vertrag: bei jedem Monatstag liegt mindestens ein Termin vor heute
  v_res JSONB; v_giro INT; v_depot INT; v_ins INT; v_rp INT; v_pen INT; v_plan INT;
  r RECORD; v_ai RECORD; v_cf RECORD; v_po RECORD; v_so RECORD;
  v_occ INT; v_flow NUMERIC; v_dates0 DATE[]; v_dates1 DATE[]; v_eff DATE; v_last DATE; v_next DATE;
  v_n_ins INT := 0; v_n_pen INT := 0; v_n_plan INT := 0;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__prop_orv_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__prop_orv_depot__','account_type','stocks_depot','currency','EUR',
            'settlement_id',v_giro))->>'account_id')::int INTO v_depot;

  -- Versicherung
  FOR r IN SELECT * FROM (VALUES
      (30.00,  'month', 1,  1::int),   (89.90, 'month', 3, NULL),  (240.00, 'month', 6, NULL),  (512.37, 'month', 12, NULL),
      (480.00, 'year',  1,  NULL), (12.50, 'month', 1, -2), (33.33, 'month', 1, NULL)) x(premium, unit, intv, dom) LOOP
    BEGIN
      v_res := finance.fn_create_insurance(jsonb_build_object('name','__prop_orv_ins__','premium_amount',r.premium,
        'schedule_unit',r.unit,'schedule_interval',r.intv,'first_payment_date',v_first,'debit_account_id',v_giro)
        || CASE WHEN r.dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', r.dom) END);
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V setup insurance %: %', r, v_res; END IF;
      v_ins := (v_res->>'insurance_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
      SELECT * INTO v_ai FROM finance.active_insurances WHERE id = v_ins;
      SELECT * INTO v_cf FROM finance.monthly_cashflow_overview WHERE id = v_rp;
      SELECT f.monthly INTO v_flow FROM finance.fn_account_flows(v_giro) f WHERE f.rp_id = v_rp;
      SELECT min(d) INTO v_next FROM finance.fn_schedule_occurrences((SELECT first_payment_date FROM finance.recurring_payments WHERE id = v_rp),
          r.intv, r.unit::finance.schedule_unit, r.dom::smallint, NULL, v_t, v_t + 800) d;
      SELECT count(*) INTO v_occ FROM finance.fn_upcoming_payments(v_next, (v_next + interval '1 year')::date - 1) u WHERE u.recurring_payment_id = v_rp;
      -- V1
      IF v_ai.premium_amount IS DISTINCT FROM r.premium OR v_ai.annual_premium IS DISTINCT FROM r.premium * v_occ THEN
        RAISE EXCEPTION 'FAIL V1 insurance %: Beitrag % Jahresbeitrag %, Termine im Jahr % x Beitrag = %', r, v_ai.premium_amount, v_ai.annual_premium, v_occ, r.premium * v_occ; END IF;
      IF abs(v_ai.monthly_equivalent - v_ai.annual_premium / 12) > 0.005 THEN
        RAISE EXCEPTION 'FAIL V1 insurance %: Monatswert % <> Jahresbeitrag/12 %', r, v_ai.monthly_equivalent, v_ai.annual_premium / 12; END IF;
      IF v_cf.monthly_equivalent IS DISTINCT FROM -v_ai.monthly_equivalent OR v_cf.consumption_eur IS DISTINCT FROM -v_ai.monthly_equivalent
         OR v_flow IS DISTINCT FROM -v_ai.monthly_equivalent OR v_cf.cashflow_class <> 'consumption' THEN
        RAISE EXCEPTION 'FAIL V1 insurance %: Vertrag % Monatsrechnung %/% (%) Konto-Sicht %', r, v_ai.monthly_equivalent, v_cf.monthly_equivalent, v_cf.consumption_eur, v_cf.cashflow_class, v_flow; END IF;
      -- V2
      IF (v_res->>'premium_amount')::numeric IS DISTINCT FROM v_ai.premium_amount OR (v_res->>'annual_premium')::numeric IS DISTINCT FROM v_ai.annual_premium
         OR (v_res->>'monthly_equivalent')::numeric IS DISTINCT FROM v_ai.monthly_equivalent THEN
        RAISE EXCEPTION 'FAIL V2 insurance %: Rueckgabe % gegen View %/%/%', r, v_res - 'card_lines', v_ai.premium_amount, v_ai.annual_premium, v_ai.monthly_equivalent; END IF;
      -- V3: Beitrag + 10 ab einem Stichtag mitten im Raster (erster Termin + 100 Tage)
      SELECT array_agg(u.due_date ORDER BY u.due_date) INTO v_dates0 FROM finance.fn_upcoming_payments(v_t, v_t + 1200) u WHERE u.recurring_payment_id = v_rp;
      v_eff := v_next + 100;
      v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id',v_ins,'premium_amount',r.premium + 10,'effective_from',v_eff));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V3 insurance %: %', r, v_res; END IF;
      SELECT array_agg(u.due_date ORDER BY u.due_date) INTO v_dates1 FROM finance.fn_upcoming_payments(v_t, v_t + 1200) u
        WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
      IF v_dates1 IS DISTINCT FROM v_dates0 THEN
        RAISE EXCEPTION 'FAIL V3 insurance % stichtag %: Termine vorher % nachher %', r, v_eff, v_dates0, v_dates1; END IF;
      IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 1200) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))
                   AND u.amount IS DISTINCT FROM CASE WHEN u.due_date < v_eff THEN -r.premium ELSE -(r.premium + 10) END) THEN
        RAISE EXCEPTION 'FAIL V3 insurance % stichtag %: Betrag wechselt nicht am Stichtag', r, v_eff; END IF;
      IF (v_res->>'premium_amount')::numeric IS DISTINCT FROM r.premium + 10 THEN
        RAISE EXCEPTION 'FAIL V2 insurance %: Rueckgabe nennt nicht den neuen Beitrag: %', r, v_res; END IF;
      -- heute gilt noch der alte Beitrag
      IF (SELECT premium_amount FROM finance.active_insurances WHERE id = v_ins) IS DISTINCT FROM r.premium THEN
        RAISE EXCEPTION 'FAIL V3 insurance %: View zeigt vor dem Stichtag schon den neuen Beitrag', r; END IF;
      -- V4: Vertragsende 400 Tage nach dem ersten Termin
      v_last := v_next + 400;
      v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id',v_ins,'valid_to',v_last));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V4 insurance %: %', r, v_res; END IF;
      IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 1200) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp)) AND u.due_date > v_last) THEN
        RAISE EXCEPTION 'FAIL V4 insurance %: Termin nach dem Vertragsende %', r, v_last; END IF;
      IF (SELECT array_agg(u.due_date ORDER BY u.due_date) FROM finance.fn_upcoming_payments(v_t, v_t + 1200) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp)))
         IS DISTINCT FROM ARRAY(SELECT d FROM unnest(v_dates0) d WHERE d <= v_last ORDER BY d) THEN
        RAISE EXCEPTION 'FAIL V4 insurance %: Termine bis zum Ende weichen ab', r; END IF;
      IF (SELECT last_valid_day FROM finance.active_insurances WHERE id = v_ins) IS DISTINCT FROM v_last THEN
        RAISE EXCEPTION 'FAIL V4 insurance %: View nennt als letzten Tag %, gesetzt %', r, (SELECT last_valid_day FROM finance.active_insurances WHERE id = v_ins), v_last; END IF;
      v_n_ins := v_n_ins + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;

  -- Vorsorge-Beitrag
  FOR r IN SELECT * FROM (VALUES (80.00, 'month', 1), (250.00, 'month', 3), (1200.00, 'year', 1), (25.00, 'week', 1)) x(amt, unit, intv) LOOP
    BEGIN
      v_res := finance.fn_create_pension(jsonb_build_object('name','__prop_orv_pen__','pension_type','private','contribution_amount',r.amt,
        'schedule_unit',r.unit,'schedule_interval',r.intv,'debit_account_id',v_giro,'first_payment_date',v_first));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V setup pension %: %', r, v_res; END IF;
      v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
      SELECT * INTO v_po FROM finance.pension_overview WHERE id = v_pen;
      SELECT * INTO v_cf FROM finance.monthly_cashflow_overview WHERE id = v_rp;
      SELECT f.monthly INTO v_flow FROM finance.fn_account_flows(v_giro) f WHERE f.rp_id = v_rp;
      IF v_po.contribution_amount IS DISTINCT FROM r.amt OR v_po.monthly_contribution IS DISTINCT FROM -finance.fn_monthly_equivalent(r.amt, r.intv, r.unit::finance.schedule_unit)
         OR v_po.monthly_contribution >= 0 THEN
        RAISE EXCEPTION 'FAIL V1 pension %: Beitrag % Monatswert %', r, v_po.contribution_amount, v_po.monthly_contribution; END IF;
      IF v_cf.monthly_equivalent IS DISTINCT FROM v_po.monthly_contribution OR v_cf.saving_eur IS DISTINCT FROM v_po.monthly_contribution
         OR v_flow IS DISTINCT FROM v_po.monthly_contribution OR v_cf.cashflow_class <> 'saving' THEN
        RAISE EXCEPTION 'FAIL V1 pension %: Vertrag % Monatsrechnung %/% (%) Konto-Sicht %', r, v_po.monthly_contribution, v_cf.monthly_equivalent, v_cf.saving_eur, v_cf.cashflow_class, v_flow; END IF;
      v_n_pen := v_n_pen + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;

  -- Sparplan (Monatsrhythmus, kein Depot-Kalender noetig)
  FOR r IN SELECT * FROM (VALUES (150.00, 1, 1::int), (75.00, 1, 15), (300.00, 3, NULL), (50.00, 1, -1)) x(amt, intv, dom) LOOP
    BEGIN
      v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_orv_plan__','depot_name','__prop_orv_depot__',
        'isin','IE00B3RBWM25','symbol','VWCE','security_name','Testfonds Welt','amount',r.amt,'schedule_interval',r.intv,
        'schedule_unit','month','schedule_day_of_month',r.dom,'first_payment_date',v_first));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V setup plan %: %', r, v_res; END IF;
      v_plan := (v_res->>'savings_plan_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
      -- ueberfaellige Ausfuehrungen erledigen (fn_set_savings_plan verlangt das vor einem Stichtag)
      PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', o.recurring_payment_id, 'due_date', o.due_date))
        FROM finance.fn_recurring_due_open(v_t - 1) o WHERE o.recurring_payment_id = v_rp;
      SELECT * INTO v_so FROM finance.savings_plan_overview WHERE id = v_plan;
      SELECT * INTO v_cf FROM finance.monthly_cashflow_overview WHERE id = v_rp;
      SELECT f.monthly INTO v_flow FROM finance.fn_account_flows(v_giro) f WHERE f.rp_id = v_rp;
      SELECT min(u.due_date) INTO v_next FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id = v_rp;
      IF v_so.amount_per_execution IS DISTINCT FROM r.amt OR v_so.monthly_amount IS DISTINCT FROM (v_res->>'monthly_amount')::numeric
         OR v_cf.monthly_equivalent IS DISTINCT FROM -v_so.monthly_amount OR v_flow IS DISTINCT FROM -v_so.monthly_amount
         OR v_cf.saving_eur IS DISTINCT FROM -v_so.monthly_amount THEN
        RAISE EXCEPTION 'FAIL V1/V2 plan %: Uebersicht %/% Rueckgabe % Monatsrechnung %/% Konto-Sicht %', r, v_so.amount_per_execution, v_so.monthly_amount,
          v_res->>'monthly_amount', v_cf.monthly_equivalent, v_cf.saving_eur, v_flow; END IF;
      IF v_so.next_execution IS DISTINCT FROM v_next THEN
        RAISE EXCEPTION 'FAIL V5 plan %: Uebersicht naechste Ausfuehrung %, frueheste offene %', r, v_so.next_execution, v_next; END IF;
      -- geplante Betrags-Aenderung ab erstem Termin + 45 Tage
      SELECT array_agg(u.due_date ORDER BY u.due_date) INTO v_dates0 FROM finance.fn_upcoming_payments(v_t, v_t + 800) u WHERE u.recurring_payment_id = v_rp;
      v_eff := v_next + 45;
      v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_orv_plan__','new_amount',r.amt + 25,'valid_from',v_eff));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V3 plan %: %', r, v_res; END IF;
      SELECT * INTO v_so FROM finance.savings_plan_overview WHERE id = v_plan;
      SELECT array_agg(u.due_date ORDER BY u.due_date) INTO v_dates1 FROM finance.fn_upcoming_payments(v_t, v_t + 800) u
        WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
      IF v_dates1 IS DISTINCT FROM v_dates0 THEN
        RAISE EXCEPTION 'FAIL V3 plan % stichtag %: Termine vorher % nachher %', r, v_eff, v_dates0, v_dates1; END IF;
      IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 800) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))
                   AND u.amount IS DISTINCT FROM CASE WHEN u.due_date < v_eff THEN -r.amt ELSE -(r.amt + 25) END) THEN
        RAISE EXCEPTION 'FAIL V3 plan % stichtag %: Betrag wechselt nicht am Stichtag', r, v_eff; END IF;
      IF v_so.amount_per_execution IS DISTINCT FROM r.amt OR v_so.change_from IS DISTINCT FROM v_eff
         OR v_so.new_amount_per_execution IS DISTINCT FROM r.amt + 25 OR v_so.next_execution IS DISTINCT FROM v_next THEN
        RAISE EXCEPTION 'FAIL V5 plan %: nach geplanter Aenderung zeigt die Uebersicht Betrag % ab % neu % naechste % (erwartet % / % / % / %)', r,
          v_so.amount_per_execution, v_so.change_from, v_so.new_amount_per_execution, v_so.next_execution, r.amt, v_eff, r.amt + 25, v_next; END IF;
      IF (v_res->>'monthly_amount')::numeric IS DISTINCT FROM (SELECT abs(monthly_equivalent) FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int) THEN
        RAISE EXCEPTION 'FAIL V2 plan %: Rueckgabe monthly_amount', r; END IF;
      v_n_plan := v_n_plan + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;

  -- V6: Vertrag startet erst in 6 Tagen und hat schon eine geplante Aenderung (ab in 106 Tagen)
  DECLARE v_start DATE := current_date + 6; v_chg DATE := current_date + 106; v_head INT;
  BEGIN
    -- Versicherung 30 -> 40
    v_res := finance.fn_create_insurance(jsonb_build_object('name','__prop_orv_v6_ins__','premium_amount',30,'schedule_unit','month',
      'first_payment_date',v_start,'debit_account_id',v_giro));
    v_ins := (v_res->>'insurance_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id',v_ins,'premium_amount',40,'effective_from',v_chg));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V6 setup insurance: %', v_res; END IF;
    IF (SELECT premium_amount FROM finance.active_insurances WHERE id = v_ins) IS DISTINCT FROM 30
       OR (SELECT -sum(monthly_equivalent) FROM finance.monthly_cashflow_overview WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))) IS DISTINCT FROM 30 THEN
      RAISE EXCEPTION 'FAIL V6 Versicherung vor dem Start: Vertrags-Sicht %, Monatsrechnung % (Start-Beitrag 30)',
        (SELECT premium_amount FROM finance.active_insurances WHERE id = v_ins),
        (SELECT -sum(monthly_equivalent) FROM finance.monthly_cashflow_overview WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))); END IF;
    -- Sparplan 150 -> 200
    v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_orv_v6_plan__','depot_name','__prop_orv_depot__',
      'isin','IE00B3RBWM25','symbol','VWCE','security_name','Testfonds Welt','amount',150,'schedule_interval',1,'schedule_unit','month','first_payment_date',v_start));
    v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_orv_v6_plan__','new_amount',200,'valid_from',v_chg));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V6 setup plan: %', v_res; END IF;
    SELECT * INTO v_so FROM finance.savings_plan_overview WHERE name = '__prop_orv_v6_plan__';
    SELECT min(u.due_date) INTO v_next FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
    IF v_so.amount_per_execution IS DISTINCT FROM 150 OR v_so.next_execution IS DISTINCT FROM v_next OR v_so.starts_on IS DISTINCT FROM v_next
       OR v_so.change_from IS DISTINCT FROM v_chg OR v_so.new_amount_per_execution IS DISTINCT FROM 200 THEN
      RAISE EXCEPTION 'FAIL V6 Sparplan vor dem Start: Uebersicht Betrag % startet % naechste % Aenderung ab % neu % (erwartet 150 / % / % / % / 200)',
        v_so.amount_per_execution, v_so.starts_on, v_so.next_execution, v_so.change_from, v_so.new_amount_per_execution, v_next, v_next, v_chg; END IF;
    -- Vorsorge 80 -> 90 (Aenderung ueber den gemeinsamen Helfer der Vertrags-Ketten)
    v_res := finance.fn_create_pension(jsonb_build_object('name','__prop_orv_v6_pen__','pension_type','private','contribution_amount',80,
      'debit_account_id',v_giro,'first_payment_date',v_start));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_change_owned_recurring(v_rp, v_chg, -90, NULL, NULL, NULL);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V6 setup pension: %', v_res; END IF;
    IF (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen) IS DISTINCT FROM 80
       OR (SELECT monthly_contribution FROM finance.pension_overview WHERE id = v_pen) IS DISTINCT FROM -80 THEN
      RAISE EXCEPTION 'FAIL V6 Vorsorge vor dem Start: Sicht Beitrag % / Monat % (Start-Beitrag 80)',
        (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen), (SELECT monthly_contribution FROM finance.pension_overview WHERE id = v_pen); END IF;
    -- die Regel selbst: vor dem Start das naechste startende Glied, am Stichtag der Aenderung und danach der Kopf
    v_head := finance.fn_recurring_lineage_head(v_rp);
    IF finance.fn_recurring_current(v_head, v_t) IS DISTINCT FROM v_rp OR finance.fn_recurring_current(v_rp, v_chg - 1) IS DISTINCT FROM v_rp
       OR finance.fn_recurring_current(v_rp, v_chg) IS DISTINCT FROM v_head OR finance.fn_recurring_current(v_rp, v_chg + 4000) IS DISTINCT FROM v_head THEN
      RAISE EXCEPTION 'FAIL V6 fn_recurring_current: heute % (erwartet %), am Stichtag % (erwartet %)', finance.fn_recurring_current(v_head, v_t), v_rp,
        finance.fn_recurring_current(v_rp, v_chg), v_head; END IF;
    -- V7: eine Aenderung zum Stichtag der geplanten Aenderung vergleicht mit dem Glied, das an dem Stichtag gilt.
    -- Derselbe Betrag wie geplant aendert die Termine nicht; der Start-Betrag zum selben Stichtag nimmt die Erhoehung zurueck.
    v_rp := (SELECT recurring_payment_id FROM finance.insurances WHERE id = v_ins);
    v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id',v_ins,'premium_amount',40,'effective_from',v_chg));
    IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))
                 AND u.amount IS DISTINCT FROM CASE WHEN u.due_date < v_chg THEN -30 ELSE -40 END) THEN
      RAISE EXCEPTION 'FAIL V7 Versicherung: gleicher geplanter Beitrag veraendert die Vorschau (%)', v_res - 'card_lines'; END IF;
    v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id',v_ins,'premium_amount',30,'effective_from',v_chg));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u
                   WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage((SELECT recurring_payment_id FROM finance.insurances WHERE id = v_ins)))
                     AND u.amount IS DISTINCT FROM -30) THEN
      RAISE EXCEPTION 'FAIL V7 Versicherung: Erhoehung zum Stichtag zuruecknehmen (30) wirkt nicht: % | Vorschau %', v_res - 'card_lines',
        (SELECT string_agg(u.due_date || '=' || u.amount, ',' ORDER BY u.due_date) FROM finance.fn_upcoming_payments(v_t, v_t + 200) u
          WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage((SELECT recurring_payment_id FROM finance.insurances WHERE id = v_ins)))); END IF;
  END;

  -- V8: zwei Fragen, zwei Adressen. "Startet am" (fn_recurring_starts_on: erster Termin des Glieds, gleich welcher
  -- Status, gleich was erledigt ist) und "erster offener Termin" (fn_recurring_first_due: nach dem juengsten erledigten,
  -- NULL bei pausierter Zeile) gegen dieselbe Zahlung in vier Lagen.
  DECLARE v_start DATE := current_date + 10; v_first DATE; v_second DATE;
  BEGIN
    -- Lage 1: Sparplan vor dem Start, pausiert -> die Uebersicht nennt weiter den Start, offen ist nichts
    v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_orv_v8_plan__','depot_name','__prop_orv_depot__',
      'isin','IE00B4L5Y983','symbol','IUSQ','security_name','Testfonds Zwei','amount',60,'schedule_interval',1,'schedule_unit','month','first_payment_date',v_start));
    v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_orv_v8_plan__','status','paused'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V8 setup pause: %', v_res; END IF;
    IF (SELECT starts_on FROM finance.savings_plan_overview WHERE name = '__prop_orv_v8_plan__') IS DISTINCT FROM v_start
       OR finance.fn_recurring_starts_on(v_rp) IS DISTINCT FROM v_start OR finance.fn_recurring_first_due(v_rp) IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL V8 [pausiert, vor dem Start]: Uebersicht startet %, starts_on %, first_due % (erwartet % / % / NULL)',
        (SELECT starts_on FROM finance.savings_plan_overview WHERE name = '__prop_orv_v8_plan__'), finance.fn_recurring_starts_on(v_rp),
        finance.fn_recurring_first_due(v_rp), v_start, v_start; END IF;
    -- Lage 2: vor dem Start, aktiv -> beide nennen den ersten Termin
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_orv_v8_plan__','status','active'));
    IF finance.fn_recurring_starts_on(v_rp) IS DISTINCT FROM v_start OR finance.fn_recurring_first_due(v_rp) IS DISTINCT FROM v_start THEN
      RAISE EXCEPTION 'FAIL V8 [aktiv, vor dem Start]: starts_on % first_due % (erwartet beide %)', finance.fn_recurring_starts_on(v_rp), finance.fn_recurring_first_due(v_rp), v_start; END IF;
    -- Lage 3: laufende Zahlung mit gebuchtem ersten Termin -> starts_on bleibt der erste Termin, first_due ist der naechste
    v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__prop_orv_v8_rp__','account_id',v_giro,'direction','income','amount',10,
      'schedule_unit','month','first_payment_date',v_t - 40));
    v_rp := (v_res->>'recurring_payment_id')::int;
    SELECT min(d), max(d) INTO v_first, v_second FROM (SELECT o.due_date AS d FROM finance.fn_recurring_due_open(v_t - 60, v_t + 60) o
                                                       WHERE o.recurring_payment_id = v_rp ORDER BY 1 LIMIT 2) q;
    PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_first));
    IF finance.fn_recurring_starts_on(v_rp) IS DISTINCT FROM v_first OR finance.fn_recurring_first_due(v_rp) IS DISTINCT FROM v_second THEN
      RAISE EXCEPTION 'FAIL V8 [gebuchter erster Termin]: starts_on % (erwartet %), first_due % (erwartet %)', finance.fn_recurring_starts_on(v_rp), v_first,
        finance.fn_recurring_first_due(v_rp), v_second; END IF;
    -- Lage 4: Enddatum vor dem ersten Termin -> kein offener Termin; starts_on faellt auf den Geltungsbeginn
    v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__prop_orv_v8_end__','account_id',v_giro,'direction','income','amount',10,
      'schedule_unit','year','first_payment_date',v_t + 200,'valid_from',v_t + 20,'valid_to',v_t + 50));
    v_rp := (v_res->>'recurring_payment_id')::int;
    IF finance.fn_recurring_first_due(v_rp) IS NOT NULL OR finance.fn_recurring_starts_on(v_rp) IS DISTINCT FROM v_t + 20 THEN
      RAISE EXCEPTION 'FAIL V8 [Ende vor dem ersten Termin]: starts_on % first_due %', finance.fn_recurring_starts_on(v_rp), finance.fn_recurring_first_due(v_rp); END IF;
  END;
  -- V9: "laeuft schon so" vergleicht mit dem Glied, das am Stichtag gilt. Sparplan vor dem Start mit geplanter Aenderung
  -- (150, ab in 106 Tagen 200): 150 ab heute und 200 ab dem Stichtag der Aenderung sind beide keine Aenderung.
  DECLARE v_chg DATE := current_date + 106; v_sig TEXT;
  BEGIN
    v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_orv_v9_plan__','depot_name','__prop_orv_depot__',
      'isin','IE00B5BMR087','symbol','CSPX','security_name','Testfonds Drei','amount',150,'schedule_interval',1,'schedule_unit','month','first_payment_date',current_date + 6));
    v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_orv_v9_plan__','new_amount',200,'valid_from',v_chg));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL V9 setup: %', v_res; END IF;
    SELECT string_agg(u.due_date || '=' || u.amount, ',' ORDER BY u.due_date) INTO v_sig FROM finance.fn_upcoming_payments(v_t, v_t + 300) u
     WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_orv_v9_plan__','new_amount',150));
    IF (v_res->>'code') IS DISTINCT FROM 'no_change' OR (v_res->>'amount_per_execution')::numeric IS DISTINCT FROM 150 THEN
      RAISE EXCEPTION 'FAIL V9 [150 ab heute, es laeuft 150]: erwartet no_change mit 150, got %', v_res; END IF;
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_orv_v9_plan__','new_amount',200,'valid_from',v_chg));
    IF (v_res->>'code') IS DISTINCT FROM 'no_change' OR (v_res->>'amount_per_execution')::numeric IS DISTINCT FROM 200 THEN
      RAISE EXCEPTION 'FAIL V9 [200 ab dem Stichtag, geplant ist 200]: erwartet no_change mit 200, got %', v_res; END IF;
    IF (SELECT string_agg(u.due_date || '=' || u.amount, ',' ORDER BY u.due_date) FROM finance.fn_upcoming_payments(v_t, v_t + 300) u
         WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))) IS DISTINCT FROM v_sig THEN
      RAISE EXCEPTION 'FAIL V9: eine Wiederholung hat die Vorschau veraendert'; END IF;
  END;

  -- eine Definition je Frage: der Name kommt im Katalog genau einmal vor (zwei Dateien mit derselben Signatur wuerden sich
  -- je nach Einspiel-Reihenfolge still ueberschreiben)
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'finance' AND p.proname = 'fn_recurring_first_due') <> 1
     OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'finance' AND p.proname = 'fn_recurring_starts_on') <> 1 THEN
    RAISE EXCEPTION 'FAIL V8: fn_recurring_first_due / fn_recurring_starts_on nicht je genau einmal definiert'; END IF;

  RAISE NOTICE 'PASS prop owned recurring views [Versicherung: % Faelle (V1-V4), Vorsorge: % (V1), Sparplan: % (V1-V3, V5), vor dem Start mit geplanter Aenderung: 3 Vertragsarten (V6, V7)]', v_n_ins, v_n_pen, v_n_plan;
END $$;

ROLLBACK;
