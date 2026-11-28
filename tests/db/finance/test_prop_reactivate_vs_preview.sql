-- tests/db/finance/test_prop_reactivate_vs_preview.sql
-- Eigenschafts-Test: einen Vertrag beenden oder pausieren und wieder aktivieren, gegen die Vorschau.
--   A1 nach dem Beenden/Pausieren zeigt die Vorschau keinen Termin und die Monatsrechnung keine Zeile mehr
--   A2 nach dem Reaktivieren zeigt die Vorschau wieder Termine, die Monatsrechnung den Beitrag, und die Vertrags-Sicht
--      nennt denselben Betrag; ein schon gebuchter Termin wird nicht erneut faellig
-- Vertragsarten: Vorsorge (schliessen mit Historie -> aktiv; pausieren -> aktiv), Sparplan (schliessen mit Historie -> aktiv).
BEGIN;

DO $$
DECLARE
  v_t DATE := current_date;
  v_res JSONB; v_giro INT; v_depot INT; v_pen INT; v_rp INT; v_head INT; v_how TEXT; v_n INT := 0; v_cnt INT; v_booked DATE;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__prop_rvp_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__prop_rvp_depot__','account_type','stocks_depot','currency','EUR',
            'settlement_id',v_giro))->>'account_id')::int INTO v_depot;
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id',v_giro,'amount',9000,'direction','inflow','transaction_date',v_t - 90));

  -- Vorsorge
  FOREACH v_how IN ARRAY ARRAY['close', 'pause'] LOOP
    BEGIN
      v_res := finance.fn_create_pension(jsonb_build_object('name','__prop_rvp_pen__','pension_type','private','contribution_amount',80,
        'debit_account_id',v_giro,'first_payment_date',v_t - 40));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A setup pension: %', v_res; END IF;
      v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
      v_booked := v_t - 40;
      v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_booked));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A setup book: %', v_res; END IF;
      PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',o.recurring_payment_id,'due_date',o.due_date))
        FROM finance.fn_recurring_due_open(v_t - 1) o WHERE o.recurring_payment_id = v_rp;
      IF v_how = 'close' THEN
        v_res := finance.fn_close_pension(jsonb_build_object('pension_name','__prop_rvp_pen__'));
      ELSE
        v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'status','paused'));
      END IF;
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A [%]: %', v_how, v_res; END IF;
      -- A1
      IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp)))
         OR EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_rp))) THEN
        RAISE EXCEPTION 'FAIL A1 Vorsorge [%]: nach dem Beenden noch Termine oder eine Zeile in der Monatsrechnung', v_how; END IF;
      v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'status','active'));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A2 Vorsorge [%]: Reaktivieren abgelehnt %', v_how, v_res; END IF;
      -- A2
      v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
      SELECT count(*) INTO v_cnt FROM finance.fn_upcoming_payments(v_t, v_t + 100) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head));
      IF v_cnt < 2 THEN
        RAISE EXCEPTION 'FAIL A2 Vorsorge [%]: reaktiviert (ok), aber nur % Termine in den naechsten 100 Tagen', v_how, v_cnt; END IF;
      IF (SELECT -sum(m.monthly_equivalent) FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_head))) IS DISTINCT FROM 80
         OR (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen) IS DISTINCT FROM 80
         OR (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_head THEN
        RAISE EXCEPTION 'FAIL A2 Vorsorge [%]: Monatsrechnung %, Sicht %, Rueckgabe rp % (Kopf %)', v_how,
          (SELECT -sum(m.monthly_equivalent) FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_head))),
          (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen), v_res->>'recurring_payment_id', v_head; END IF;
      IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_t - 400, v_t + 400) o
                  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head)) AND o.due_date <= v_booked) THEN
        RAISE EXCEPTION 'FAIL A2 Vorsorge [%]: gebuchter Termin wieder offen', v_how; END IF;
      v_n := v_n + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;

  -- Sparplan: schliessen (mit einer uebersprungenen Ausfuehrung als Historie bleibt nur Soft-Close bei Buchung; hier Skip + Pause/Aktiv)
  BEGIN
    v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_rvp_plan__','depot_name','__prop_rvp_depot__',
      'isin','IE00B3RBWM25','symbol','VWCE','security_name','Testfonds Welt','amount',150,'schedule_interval',1,'schedule_unit','month','first_payment_date',v_t - 40));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A setup plan: %', v_res; END IF;
    v_rp := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',o.recurring_payment_id,'due_date',o.due_date))
      FROM finance.fn_recurring_due_open(v_t - 1) o WHERE o.recurring_payment_id = v_rp;
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_rvp_plan__','status','paused'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A plan pause: %', v_res; END IF;
    IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp)))
       OR EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_rp))) THEN
      RAISE EXCEPTION 'FAIL A1 Sparplan: pausiert, aber noch Termine oder eine Zeile in der Monatsrechnung'; END IF;
    v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_rvp_plan__','status','active'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A2 Sparplan: %', v_res; END IF;
    v_head := (SELECT recurring_payment_id FROM finance.savings_plans WHERE name = '__prop_rvp_plan__');
    IF (SELECT count(*) FROM finance.fn_upcoming_payments(v_t, v_t + 100) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head))) < 2
       OR (SELECT -sum(m.monthly_equivalent) FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_head))) IS DISTINCT FROM 150
       OR (SELECT monthly_amount FROM finance.savings_plan_overview WHERE name = '__prop_rvp_plan__') IS DISTINCT FROM 150 THEN
      RAISE EXCEPTION 'FAIL A2 Sparplan: nach dem Fortsetzen stimmen Vorschau, Monatsrechnung oder Uebersicht nicht'; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- A3: Sparplan mit Buchungs-Historie schliessen und wieder aktivieren, ohne und mit geplanter Betrags-Aenderung.
  --     Mit geplanter Aenderung ist der Kopf der Kette ein leeres Glied in der Zukunft; "beendet" gilt fuer die ganze Kette.
  DECLARE v_planned BOOLEAN;
  BEGIN
    FOREACH v_planned IN ARRAY ARRAY[false, true] LOOP
      BEGIN
        v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_rvp_plan3__','depot_name','__prop_rvp_depot__',
          'isin','IE00B4L5Y983','symbol','IUSQ','security_name','Testfonds Zwei','amount',150,'schedule_interval',1,'schedule_unit','month','first_payment_date',v_t - 40));
        v_rp := (v_res->>'recurring_payment_id')::int;
        v_res := finance.fn_book_savings_plan_execution(jsonb_build_object('savings_plan_name','__prop_rvp_plan3__','shares',1.5,'price_per_share',100));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A3 setup book: %', v_res; END IF;
        PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',o.recurring_payment_id,'due_date',o.due_date))
          FROM finance.fn_recurring_due_open(v_t - 1) o WHERE o.recurring_payment_id = v_rp;
        IF v_planned THEN
          v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_rvp_plan3__','new_amount',200,'valid_from',v_t + 100));
          IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL A3 setup planned change: %', v_res; END IF;
        END IF;
        v_res := finance.fn_close_savings_plan(jsonb_build_object('savings_plan_name','__prop_rvp_plan3__'));
        IF (v_res->>'action') IS DISTINCT FROM 'closed' THEN RAISE EXCEPTION 'FAIL A3 setup close: %', v_res; END IF;
        IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))) THEN
          RAISE EXCEPTION 'FAIL A1 Sparplan geschlossen [geplante Aenderung=%]: noch Termine in der Vorschau', v_planned; END IF;
        v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_rvp_plan3__','status','active'));
        v_head := (SELECT recurring_payment_id FROM finance.savings_plans WHERE name = '__prop_rvp_plan3__');
        SELECT count(*) INTO v_cnt FROM finance.fn_upcoming_payments(v_t, v_t + 100) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_cnt < 2
           OR NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_head)))
           OR (SELECT next_execution FROM finance.savings_plan_overview WHERE name = '__prop_rvp_plan3__') IS DISTINCT FROM
              (SELECT min(u.due_date) FROM finance.fn_upcoming_payments(v_t, v_t + 100) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head))) THEN
          RAISE EXCEPTION 'FAIL A2 Sparplan [geplante Aenderung=%]: reaktiviert ok=%, % Termine in 100 Tagen, Uebersicht naechste %, Glieder %', v_planned, v_res->>'ok', v_cnt,
            (SELECT next_execution FROM finance.savings_plan_overview WHERE name = '__prop_rvp_plan3__'),
            (SELECT string_agg(amount || ' ' || status || ' [' || valid_from || '..' || coalesce(valid_to::text, '-') || ')', ' | ' ORDER BY valid_from, id)
               FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))); END IF;
        IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_t - 400, v_t + 400) o
                    WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head)) AND o.due_date < v_t) THEN
          RAISE EXCEPTION 'FAIL A2 Sparplan [geplante Aenderung=%]: erledigter Termin wieder offen', v_planned; END IF;
        v_n := v_n + 1;
        RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
      EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
      END;
    END LOOP;
  END;

  RAISE NOTICE 'PASS prop reactivate vs preview [% Faelle, A1-A3]', v_n;
END $$;

ROLLBACK;
