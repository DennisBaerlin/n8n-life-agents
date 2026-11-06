-- tests/db/finance/test_fn_reopen_recurring_payment.sql
-- Audit Paket 2, Punkt 1 (+2): Sparplan nach Soft-Close wieder aktivieren.
--   Vorher: fn_set_savings_plan(status=active) setzte nur status='active' auf die beendete rp (valid_to blieb)
--   -> Plan "aktiv", aber nie wieder faellig. Jetzt: Folge-rp ab dem Reaktivierungstag (fn_reopen_recurring_payment),
--   Raster (Anker) geerbt, Luecke nie faellig, Besitzer zeigt auf den Kopf.
--   Randfaelle: Reaktivierung genau an einem Faelligkeitstag; danach Split der Kette; Schliessen zaehlt die Kette.
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_settle INT;
  v_plan   INT;
  v_rp_old INT;
  v_rp_new INT;
  v_rp3    INT;
  v_cnt    INT;
  v_due    DATE;
  v_rp_due INT;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_reo_settle__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_settle;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_reo_depot__','account_type','stocks_depot',
    'currency','EUR','settlement_id', v_settle));
  -- Depot-Kalender: echte 7-Tage-Abstaende (sonst fragt fn_resolve_plan_schedule bei woechentlich nach)
  UPDATE finance.accounts SET plan_execution_days = '{}' WHERE name = '__test_reo_depot__';
  -- woechentlich, Anker vor 14 Tagen -> Vorkommen -14, -7, heute
  SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_reo_plan__','depot_name','__test_reo_depot__',
    'isin','IE00B3RBWM25','symbol','VWCE','security_name','Vanguard FTSE All-World','amount',50,
    'schedule_interval',1,'schedule_unit','week','first_payment_date',(CURRENT_DATE - 14)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL plan: %', v_res; END IF;
  v_plan := (v_res->>'savings_plan_id')::int;
  v_rp_old := (v_res->>'recurring_payment_id')::int;

  -- Historie: -14 ausgefuehrt, -7 uebersprungen; dann schliessen (Soft-Close, valid_to = heute)
  SELECT finance.fn_book_savings_plan_execution(jsonb_build_object('savings_plan_name','__test_reo_plan__',
    'shares',1,'price_per_share',50)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL exec: %', v_res; END IF;
  PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp_old,
    'due_date', (CURRENT_DATE - 7)::text));
  SELECT finance.fn_close_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_plan__')) INTO v_res;
  IF v_res->>'action' IS DISTINCT FROM 'closed' THEN RAISE EXCEPTION 'SETUP FAIL close: %', v_res; END IF;

  -- 1. Reaktivieren heute (= Faelligkeitstag): Folge-rp, heutiges Vorkommen faellig, sonst nichts
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_plan__','status','active')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL reopen [ok]: %', v_res; END IF;
  SELECT recurring_payment_id INTO v_rp_new FROM finance.savings_plans WHERE id = v_plan;
  IF v_rp_new = v_rp_old THEN RAISE EXCEPTION 'FAIL reopen [Folge-rp]: Plan zeigt weiter auf die beendete rp'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp_new AND predecessor_id = v_rp_old
                 AND status = 'active' AND valid_from = CURRENT_DATE AND valid_to IS NULL
                 AND first_payment_date = CURRENT_DATE - 14 AND amount = -50) THEN
    RAISE EXCEPTION 'FAIL reopen [Folge-rp Felder]: %', (SELECT to_jsonb(r) FROM finance.recurring_payments r WHERE id = v_rp_new); END IF;
  IF (SELECT status::text FROM finance.savings_plans WHERE id = v_plan) IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL reopen [plan.status]'; END IF;
  SELECT count(*), min(o.due_date), min(o.recurring_payment_id) INTO v_cnt, v_due, v_rp_due
  FROM finance.fn_recurring_due_open(CURRENT_DATE) o
  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp_new));
  IF v_cnt <> 1 OR v_due <> CURRENT_DATE OR v_rp_due <> v_rp_new THEN
    RAISE EXCEPTION 'FAIL reopen [faellig]: erwartet genau heute auf der Folge-rp, got count=% due=% rp=%', v_cnt, v_due, v_rp_due; END IF;
  -- naechste Woche wieder faellig (Raster geerbt)
  IF NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE + 7) o
                 WHERE o.recurring_payment_id = v_rp_new AND o.due_date = CURRENT_DATE + 7) THEN
    RAISE EXCEPTION 'FAIL reopen [Raster]: +7 nicht faellig'; END IF;
  RAISE NOTICE 'PASS reopen [Folge-rp ab heute, Anker geerbt, Luecke nie faellig, Plan aktiv]';

  -- 2. Reaktivieren eines aktiven Plans = no-op auf der Kette (keine weitere Folge-rp)
  PERFORM finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_plan__','status','active'));
  IF (SELECT recurring_payment_id FROM finance.savings_plans WHERE id = v_plan) IS DISTINCT FROM v_rp_new THEN
    RAISE EXCEPTION 'FAIL reopen [aktiv bleibt in-place]'; END IF;
  RAISE NOTICE 'PASS reopen [aktiver Plan: Status-Set bleibt in-place]';

  -- 3. Kette nach Reopen weiter splitten: heutiges Vorkommen buchen, Betrag 80 ab morgen
  SELECT finance.fn_book_savings_plan_execution(jsonb_build_object('savings_plan_name','__test_reo_plan__',
    'shares',1,'price_per_share',50)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL reopen [exec heute]: %', v_res; END IF;
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_plan__','new_amount',80,
    'valid_from',(CURRENT_DATE + 1)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL reopen [split nach reopen]: %', v_res; END IF;
  v_rp3 := (v_res->>'recurring_payment_id')::int;
  SELECT count(*) INTO v_cnt FROM finance.fn_recurring_lineage(v_rp_old);
  IF v_cnt <> 3 OR finance.fn_recurring_lineage_head(v_rp_old) <> v_rp3 THEN
    RAISE EXCEPTION 'FAIL reopen [Kette 3 Glieder]: count=% head=%', v_cnt, finance.fn_recurring_lineage_head(v_rp_old); END IF;
  RAISE NOTICE 'PASS reopen [Reopen + Split = eine Kette aus 3 Gliedern]';

  -- 4. Punkt 2: Schliessen zaehlt die ganze Kette (2 Ausfuehrungen auf alt/neu, 0 auf dem Kopf) -> closed, nie geloescht
  SELECT finance.fn_close_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_plan__')) INTO v_res;
  IF v_res->>'action' IS DISTINCT FROM 'closed' OR (v_res->>'tx_count')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL close [Kette]: erwartet closed/tx_count=2, got %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.savings_plans WHERE id = v_plan) THEN
    RAISE EXCEPTION 'FAIL close [Kette]: Plan mit Historie hart geloescht'; END IF;
  RAISE NOTICE 'PASS close [Buchungen ueber die ganze Kette gezaehlt -> Soft-Close]';

  -- 5. Review: Pausieren/Schliessen erfasst die ALTE rp mit noch anstehender Ausfuehrung (sonst Erinnerung fuer einen
  --    geschlossenen Plan). Plan H woechentlich ab -7: -7 und heute gebucht, Split ab +10 -> +7 liegt auf der alten rp.
  DECLARE v_h INT; v_h_old INT; BEGIN
    SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_reo_h__','depot_name','__test_reo_depot__',
      'isin','IE00BK5BQT80','symbol','VWCEH','security_name','H','amount',30,
      'schedule_interval',1,'schedule_unit','week','first_payment_date',(CURRENT_DATE - 7)::text)) INTO v_res;
    v_h := (v_res->>'savings_plan_id')::int; v_h_old := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_savings_plan_execution(jsonb_build_object('savings_plan_name','__test_reo_h__','shares',1,'price_per_share',30));
    PERFORM finance.fn_book_savings_plan_execution(jsonb_build_object('savings_plan_name','__test_reo_h__','shares',1,'price_per_share',30));
    SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_h__','new_amount',40,
      'valid_from',(CURRENT_DATE + 10)::text)) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL split H: %', v_res; END IF;
    -- Pausieren pausiert auch die alte rp; Fortsetzen aktiviert sie wieder
    PERFORM finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_h__','status','paused'));
    IF (SELECT status::text FROM finance.recurring_payments WHERE id = v_h_old) IS DISTINCT FROM 'paused' THEN
      RAISE EXCEPTION 'FAIL pause [alte rp]: alte rp mit anstehender Ausfuehrung nicht pausiert'; END IF;
    PERFORM finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_h__','status','active'));
    IF (SELECT status::text FROM finance.recurring_payments WHERE id = v_h_old) IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'FAIL resume [alte rp]'; END IF;
    -- Schliessen beendet alte UND neue rp -> +7 nicht mehr faellig
    SELECT finance.fn_close_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_h__')) INTO v_res;
    IF v_res->>'action' IS DISTINCT FROM 'closed' THEN RAISE EXCEPTION 'SETUP FAIL close H: %', v_res; END IF;
    IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE + 14) o
               WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_h_old))) THEN
      RAISE EXCEPTION 'FAIL close [ganze Kette]: Vorkommen des geschlossenen Plans weiter faellig'; END IF;
    RAISE NOTICE 'PASS pause/close [alte rp mit anstehender Ausfuehrung wird mit pausiert/beendet]';
  END;

  -- 6. Review: Schliessen und Reaktivieren am Ausfuehrungstag -> heute nicht erneut faellig (Folge-rp ab morgen)
  DECLARE v_g_old INT; v_g_new INT; BEGIN
    SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_reo_g__','depot_name','__test_reo_depot__',
      'isin','IE00B4L5Y983','symbol','IUSQG','security_name','G','amount',20,
      'schedule_interval',1,'schedule_unit','week','first_payment_date',CURRENT_DATE::text)) INTO v_res;
    v_g_old := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_savings_plan_execution(jsonb_build_object('savings_plan_name','__test_reo_g__','shares',1,'price_per_share',20));
    PERFORM finance.fn_close_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_g__'));
    PERFORM finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_reo_g__','status','active'));
    SELECT recurring_payment_id INTO v_g_new FROM finance.savings_plans WHERE name = '__test_reo_g__';
    IF (SELECT valid_from FROM finance.recurring_payments WHERE id = v_g_new) IS DISTINCT FROM CURRENT_DATE + 1
       OR EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) o
                  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_g_old))) THEN
      RAISE EXCEPTION 'FAIL reopen [selber Tag]: heutige Ausfuehrung erneut faellig'; END IF;
    RAISE NOTICE 'PASS reopen [Schliessen + Reaktivieren am Ausfuehrungstag -> kein Doppel]';
  END;
END $$;

ROLLBACK;
