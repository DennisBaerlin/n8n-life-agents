-- tests/db/finance/test_savings_goal_pace_plan.sql
-- Eigenschaft: Die Ampel eines Sparziels mit Ratenplan misst am Plan: erwartet ist, was bis heute faellig war.
--   (P1) puenktlich (alle bis heute faelligen Raten gebucht) -> nie "hinter Plan", an jedem Tag zwischen den Raten;
--   (P2) eine seit 31 Tagen faellige Rate fehlt -> hinter Plan;
--   (P3) eine seit 3 Tagen faellige, noch ungebuchte Rate (Frist 10 Tage) -> nicht hinter Plan; (P4) dieselbe uebersprungen -> hinter Plan.
-- hand-injected: savings_goals.created_at wird zurueckdatiert (Zeit vergeht im Test nicht), alle uebrigen Werte entstehen
--   ueber die echten Write-fns.
BEGIN;
DO $$
DECLARE
  v_giro INT; v_pot INT; v_res JSONB; v_goal INT; v_rp INT; v_t DATE := current_date; v_first DATE; v_td DATE; v_b JSONB;
  v_pace TEXT; v_p RECORD; v_k INT; v_dueN INT; v_bad TEXT := ''; v_d DATE;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__pp_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__pp_topf__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_pot;
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id',v_giro,'amount',9000,'direction','inflow','transaction_date',v_t - 400,'description','Startgeld'));
  -- Ziel 600 in 6 Raten zu 100; erste Rate vor k Tagen -> verschieden viele Raten schon faellig, der Abstand zur
  -- naechsten Rate wechselt von Lauf zu Lauf (2, 28, 33, ... Tage)
  FOREACH v_k IN ARRAY ARRAY[2, 28, 33, 59, 62, 90] LOOP
    v_first := v_t - v_k;
    v_td := (v_first + interval '5 months')::date;
    v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__pp_goal_'||v_k||'__','goal_type','other','target_amount',600,
      'target_date',v_td,'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',v_first));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL k=%: %', v_k, v_res; END IF;
    v_goal := (v_res->>'goal_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    UPDATE finance.savings_goals SET created_at = (v_first - 30)::timestamptz WHERE id = v_goal;
    v_dueN := 0;
    FOR v_d IN SELECT due_date FROM finance.fn_recurring_due_open(v_t) WHERE recurring_payment_id = v_rp ORDER BY due_date LOOP
      v_b := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_d));
      IF (v_b->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL book k=%: %', v_k, v_b; END IF;
      v_dueN := v_dueN + 1;
    END LOOP;
    v_pace := finance.fn_savings_goal_pace(v_goal);
    IF v_pace = 'behind' THEN
      SELECT current_amount, expected_percent, pace_drift_pp INTO v_p FROM finance.savings_goal_progress WHERE id = v_goal;
      v_bad := v_bad || format(' [P1 erste Rate vor %s Tagen, %s Raten fristgerecht gebucht: gespart %s, erwartet %s %%, Abstand %s -> %s]',
                               v_k, v_dueN, v_p.current_amount, v_p.expected_percent, v_p.pace_drift_pp, v_pace);
    END IF;
  END LOOP;
  -- P2: vor 62 Tagen begonnen, nur die erste gebucht; die zweite ist seit 31 Tagen faellig und fehlt -> behind
  v_first := v_t - 62;
  v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__pp_goal_p2__','goal_type','other','target_amount',600,
      'target_date',(v_first + interval '5 months')::date,'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',v_first));
  v_goal := (v_res->>'goal_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
  UPDATE finance.savings_goals SET created_at = (v_first - 30)::timestamptz WHERE id = v_goal;
  v_b := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_first));
  IF (v_b->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL P2 book: %', v_b; END IF;
  IF finance.fn_savings_goal_pace(v_goal) IS DISTINCT FROM 'behind' THEN
    v_bad := v_bad || format(' [P2 seit 31 Tagen faellige Rate fehlt: Ampel %s statt behind]', finance.fn_savings_goal_pace(v_goal));
  END IF;
  -- P3: erste Rate seit 3 Tagen faellig und noch nicht gebucht (Buchung kommt oft erst per Erinnerung/Kontoauszug):
  -- innerhalb von 10 Tagen noch kein Rueckstand -> nicht behind. P4: dieselbe Rate uebersprungen -> fehlt sofort -> behind.
  FOREACH v_k IN ARRAY ARRAY[3, 4] LOOP
    v_first := v_t - 3;
    v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__pp_goal_p'||v_k||'__','goal_type','other','target_amount',600,
        'target_date',(v_first + interval '5 months')::date,'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',v_first));
    v_goal := (v_res->>'goal_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    UPDATE finance.savings_goals SET created_at = (v_first - 30)::timestamptz WHERE id = v_goal;
    IF v_k = 4 THEN
      v_b := finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_first));
      IF (v_b->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL P4 skip: %', v_b; END IF;
    END IF;
    v_pace := finance.fn_savings_goal_pace(v_goal);
    IF v_k = 3 AND v_pace = 'behind' THEN
      v_bad := v_bad || ' [P3 Rate seit 3 Tagen faellig, ungebucht: Ampel behind, innerhalb der 10 Tage nicht erwartet]';
    ELSIF v_k = 4 AND v_pace IS DISTINCT FROM 'behind' THEN
      v_bad := v_bad || format(' [P4 Rate uebersprungen: Ampel %s statt behind]', v_pace);
    END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'FAIL Ampel am Ratenplan:%', v_bad; END IF;
  RAISE NOTICE 'PASS Ampel am Ratenplan';
END $$;
ROLLBACK;
