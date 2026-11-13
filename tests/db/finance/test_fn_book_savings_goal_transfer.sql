-- tests/db/finance/test_fn_book_savings_goal_transfer.sql
-- finance.fn_book_savings_goal_transfer — die eine Sparziel-Geldbewegung mit Pflicht-direction.
-- Jede Bewegung ist physisch ein Transfer (intern via fn_book_transfer, atomar); direction bestimmt, welche(s)
-- Bein(e) den savings_goal_id-Tag tragen -> der Fortschritt (savings_goal_progress.current_amount = signed
-- SUM der getaggten Tx) bewegt sich entsprechend:
--   deposit    : external -> reserve, Haben (to, +) getaggt  -> +amount
--   withdrawal : reserve -> external, Soll  (from, -) getaggt -> -amount  ("Erspartes anderweitig gebraucht")
--   relocate   : reserveA -> reserveB, beide Beine getaggt    -> 0 (nur Umzug; Gesamt bleibt gleich)
-- Guards (korrigierbar, {ok:false}, kein Write): amount<=0, direction nicht im Enum, from==to. Und:
-- schlaegt der interne fn_book_transfer fehl (Cross-Currency ohne to_amount), wird nicht gestempelt -> kein Tag,
-- current_amount unveraendert (kein stiller UPDATE WHERE id=NULL).
BEGIN;

DO $$
DECLARE
  v_res JSONB;
  v_giro INT; v_topf1 INT; v_topf2 INT; v_usd INT;
  v_goal INT;
  v_cur NUMERIC; v_cnt INT; v_acct INT; v_amt NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__sgt_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)  INTO v_res; v_giro  := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgt_topf1__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_topf1 := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgt_topf2__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_topf2 := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgt_usd__","account_type":"cash","currency":"USD","account_holder":"Test"}'::jsonb) INTO v_res; v_usd := (v_res->>'account_id')::int;

  -- Ziel mit Reserve-Topf topf1 (jedes Ziel hat eine auto-berechnete Rate; create legt keine Tx an -> Tag-Count startet 0)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__sgt_goal__','target_amount',5000,'target_date',(current_date + 365)::text,
    'monthly_savings_rate',100,'account_id',v_giro,'reserve_account_id',v_topf1,
    'schedule_day_of_month',1,'first_payment_date',current_date::text)) INTO v_res;
  v_goal := (v_res->>'goal_id')::int;

  -- ===================================================================================
  -- TEST 1: deposit giro->topf1 500 -> current 500; genau 1 getaggtes Bein = das Reserve-(Haben-)Bein (+500 auf topf1)
  -- ===================================================================================
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_topf1,
    'amount',500,'direction','deposit','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [deposit ok]: %', v_res; END IF;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF v_cur IS DISTINCT FROM 500 THEN RAISE EXCEPTION 'FAIL [deposit current]: erwartet 500, got %', v_cur; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE savings_goal_id = v_goal;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [deposit tag count]: erwartet 1 getaggtes Bein, got % (beide getaggt = Bug)', v_cnt; END IF;
  SELECT account_id, amount INTO v_acct, v_amt FROM finance.transactions WHERE savings_goal_id = v_goal;
  IF v_acct IS DISTINCT FROM v_topf1 OR v_amt IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL [deposit tagged leg]: erwartet Reserve-Bein topf1 +500, got acct=% amt=%', v_acct, v_amt; END IF;
  IF (v_res->>'current_amount')::numeric IS DISTINCT FROM 500 THEN RAISE EXCEPTION 'FAIL [deposit post-state]: current_amount im Return = %, erwartet 500', v_res->>'current_amount'; END IF;
  RAISE NOTICE 'PASS [deposit: +500 nur aufs Reserve-Bein getaggt, current 500]';

  -- ===================================================================================
  -- TEST 2: withdrawal topf1->giro 200 -> current 300 ("Erspartes anderweitig gebraucht")
  -- ===================================================================================
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_topf1,'to_account_id',v_giro,
    'amount',200,'direction','withdrawal','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [withdrawal ok]: %', v_res; END IF;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF v_cur IS DISTINCT FROM 300 THEN RAISE EXCEPTION 'FAIL [withdrawal current]: erwartet 300 (500-200), got %', v_cur; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE savings_goal_id = v_goal;
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [withdrawal tag count]: erwartet 2, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [withdrawal: -200 senkt den Fortschritt auf 300]';

  -- ===================================================================================
  -- TEST 3: relocate topf1->topf2 100 -> current unveraendert 300 (beide Beine getaggt, Netto-0)
  -- ===================================================================================
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_topf1,'to_account_id',v_topf2,
    'amount',100,'direction','relocate','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [relocate ok]: %', v_res; END IF;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF v_cur IS DISTINCT FROM 300 THEN RAISE EXCEPTION 'FAIL [relocate current]: erwartet 300 (Netto-0, nur Umzug), got %', v_cur; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE savings_goal_id = v_goal;
  IF v_cnt <> 4 THEN RAISE EXCEPTION 'FAIL [relocate tag count]: erwartet 4 (beide Beine getaggt), got %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE savings_goal_id = v_goal AND account_id = v_topf2 AND amount = 100;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [relocate to-leg]: erwartet +100 auf topf2 getaggt, got %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE savings_goal_id = v_goal AND account_id = v_topf1 AND amount = -100;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [relocate from-leg]: erwartet -100 auf topf1 getaggt, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [relocate: beide Beine getaggt, Netto-0, current bleibt 300]';

  -- ===================================================================================
  -- TEST 4: amount<=0 -> {ok:false}, kein Write
  -- ===================================================================================
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_topf1,
    'amount',0,'direction','deposit','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [amount<=0]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS [amount<=0 -> ok:false]';

  -- ===================================================================================
  -- TEST 5: direction nicht im Enum -> {ok:false} (fn ist der Enum-Backstop)
  -- ===================================================================================
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_topf1,
    'amount',50,'direction','frobnicate','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [bad direction]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS [direction nicht im Enum -> ok:false]';

  -- ===================================================================================
  -- TEST 6: from==to -> {ok:false}
  -- ===================================================================================
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_topf1,'to_account_id',v_topf1,
    'amount',50,'direction','deposit','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [from==to]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS [from==to -> ok:false]';

  -- ===================================================================================
  -- TEST 7: interner Transfer {ok:false} (Cross-Currency ohne to_amount) -> kein Tag, current bleibt 300
  -- ===================================================================================
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_usd,
    'amount',50,'direction','deposit','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [xccy no to_amount]: erwartet ok=false (interner Transfer braucht to_amount), got %', v_res; END IF;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF v_cur IS DISTINCT FROM 300 THEN RAISE EXCEPTION 'FAIL [xccy no stamp]: current muss 300 bleiben (kein Tag bei {ok:false}), got %', v_cur; END IF;
  RAISE NOTICE 'PASS [interner {ok:false} -> kein Stempel, current unverändert (Finding #10)]';
END $$;

-- ============================================================
-- Die gewollte Sparziel-Entnahme verwirft den inneren reserve_breach (sonst doppelte
-- „du hast eingegriffen"-Meldung beim absichtlichen Entnehmen). Erzwungen: der Reserve-Topf haelt zusaetzlich
-- die Reserve eines zweiten Ziels -> waehrend des inneren fn_book_transfer (Entnahme-Bein noch ungetaggt) liegt
-- der Saldo unter der reservierten Summe -> der innere Transfer wuerde reserve_breach falten; der aeussere
-- fn_book_savings_goal_transfer-Return darf es nicht durchreichen.
DO $$
DECLARE
  v_res JSONB; v_giro INT; v_topf INT; v_gA INT; v_gB INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__sgt_disc_giro__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_giro := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgt_disc_topf__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_topf := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__sgt_disc_gA__', 9000, current_date + 365, 'active') RETURNING id INTO v_gA;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__sgt_disc_gB__', 9000, current_date + 365, 'active') RETURNING id INTO v_gB;
  -- topf haelt Zweier-Ziel-Reserve: gB direkt +1000 (getaggt) + unsere gA +300 (getaggt) -> Saldo 1300, reserviert 1300.
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_topf, 1000, current_date - 20, 'transfer', v_gB, gen_random_uuid()),
    (v_topf,  300, current_date - 10, 'transfer', v_gA, gen_random_uuid());

  -- Entnahme unseres gA 300 (topf->giro). Im inneren fn_book_transfer ist das Soll-Bein noch ungetaggt ->
  -- Saldo 1000 < reserviert 1300 -> der innere Transfer faltet reserve_breach. Der aeussere Return verwirft es.
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_gA,'from_account_id',v_topf,'to_account_id',v_giro,
    'amount',300,'direction','withdrawal','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [discard ok]: %', v_res; END IF;
  IF v_res ? 'reserve_breach' THEN
    RAISE EXCEPTION 'FAIL [discard]: die Sparziel-Entnahme darf reserve_breach NICHT durchreichen, got %', v_res; END IF;
  RAISE NOTICE 'PASS [Entnahme verwirft inneren reserve_breach -> keine Doppelmeldung]';
END $$;

-- ============================================================
-- "Sparziel erreicht"-Sofort-Hinweis (Event-Fold). Nur bei direction='deposit' + current>=target
-- (B1). Withdrawal/relocate gratulieren nie — auch nicht aus einem ueber-Ziel gefuellten Topf. savings_goal_progress
-- ist ziel-skopiert (WHERE id=goal) -> keine globale-View-Isolation noetig.
--   (R1) deposit ueber die Linie -> savings_goal_reached-Note (uebertroffen).
--   (R2) withdrawal aus dem ueber-Ziel-Topf (current bleibt >= target) -> keine Note (B1).
--   (R3) relocate (current unveraendert >= target) -> keine Note (B1).
--   (R4) deposit unter Ziel -> keine Note.
-- ============================================================
DO $$
DECLARE
  v_res JSONB; v_giro INT; v_topf1 INT; v_topf2 INT; v_goal INT; v_low INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__sgr_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)  INTO v_res; v_giro  := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgr_topf1__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_topf1 := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__sgr_topf2__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_topf2 := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__sgr_goal__', 1000, current_date + 365, 'active') RETURNING id INTO v_goal;

  -- (R1) deposit 1500 giro->topf1 -> current 1500 >= target 1000 -> reached-Note (uebertroffen)
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_topf1,
    'amount',1500,'direction','deposit','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [R1 ok]: %', v_res; END IF;
  IF NOT (v_res ? 'savings_goal_reached') OR COALESCE(v_res->'savings_goal_reached'->>'note','') = '' THEN
    RAISE EXCEPTION 'FAIL [R1]: kein savings_goal_reached-Fold bei deposit current>=target, got %', v_res; END IF;
  IF v_res->'savings_goal_reached'->>'note' NOT LIKE '%exceeded%' THEN
    RAISE EXCEPTION 'FAIL [R1]: Note ohne "exceeded" (Modell-Schicht englisch) bei current 1500 > target 1000: %', v_res->'savings_goal_reached'->>'note'; END IF;
  RAISE NOTICE 'PASS [R1 WS-5: deposit über die Linie -> savings_goal_reached (übertroffen)]';

  -- (R2) withdrawal 100 topf1->giro -> current 1400 (immer noch >= target) aber withdrawal -> keine Note (B1)
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_topf1,'to_account_id',v_giro,
    'amount',100,'direction','withdrawal','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [R2 ok]: %', v_res; END IF;
  IF v_res ? 'savings_goal_reached' THEN
    RAISE EXCEPTION 'FAIL [R2 B1]: withdrawal aus über-Ziel-Topf darf NICHT gratulieren, got %', v_res; END IF;
  RAISE NOTICE 'PASS [R2 WS-5/B1: withdrawal trotz current>=target -> keine Note]';

  -- (R3) relocate 100 topf1->topf2 -> current unveraendert 1400 (>= target) aber relocate -> keine Note (B1)
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_goal,'from_account_id',v_topf1,'to_account_id',v_topf2,
    'amount',100,'direction','relocate','transaction_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [R3 ok]: %', v_res; END IF;
  IF v_res ? 'savings_goal_reached' THEN
    RAISE EXCEPTION 'FAIL [R3 B1]: relocate bei current>=target darf NICHT gratulieren, got %', v_res; END IF;
  RAISE NOTICE 'PASS [R3 WS-5/B1: relocate trotz current>=target -> keine Note]';

  -- (R4) deposit unter Ziel: neues Ziel target 5000, deposit 500 -> current 500 < 5000 -> keine Note
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__sgr_low__', 5000, current_date + 365, 'active') RETURNING id INTO v_low;
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_low,'from_account_id',v_giro,'to_account_id',v_topf1,
    'amount',500,'direction','deposit','transaction_date',current_date::text)) INTO v_res;
  IF v_res ? 'savings_goal_reached' THEN
    RAISE EXCEPTION 'FAIL [R4]: savings_goal_reached bei deposit unter Ziel (500<5000), got %', v_res; END IF;
  RAISE NOTICE 'PASS [R4 WS-5: deposit unter Ziel -> keine Note]';
END $$;

-- ---------- Sparziel-Bewegung mit Bein im Startbetrag: before_opening, kein Write, kein Tag ----------
DO $$
DECLARE
  T DATE := core.fn_today();
  v_giro INT; v_pot INT; v_goal INT; v_r JSONB;
BEGIN
  v_giro := (finance.fn_create_account(jsonb_build_object('name','__sgt_ob_giro__','account_type','cash','currency','EUR','opening_balance',5000,'opening_balance_date',(T-120)::text))->>'account_id')::int;
  v_pot  := (finance.fn_create_account(jsonb_build_object('name','__sgt_ob_pot__','account_type','cash','currency','EUR','opening_balance',300,'opening_balance_date',(T-20)::text))->>'account_id')::int;
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgt_ob_goal__','target_amount',5000,'target_date',(T+700)::text,
           'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',1,'first_payment_date',(T+30)::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP goal: %', v_r; END IF;
  v_goal := (v_r->>'goal_id')::int;

  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_pot,
           'amount',100,'direction','deposit','transaction_date',(T-25)::text));
  IF v_r->>'code' IS DISTINCT FROM 'before_opening' OR (v_r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [before_opening deposit]: %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions WHERE savings_goal_id = v_goal)
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id IN (v_giro, v_pot) AND category = 'transfer')
     OR (SELECT current_amount FROM finance.savings_goal_progress WHERE id = v_goal) IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION 'FAIL [before_opening kein Write, kein Tag]'; END IF;
  RAISE NOTICE 'PASS [before_opening: Sparziel-Bewegung ohne Write und Tag]';
END $$;

-- Eine Einzahlung, die das Ziel genau erreicht, heisst "reached", nicht "exceeded".
DO $$
DECLARE v_res JSONB; v_giro INT; v_topf INT; v_goal INT;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__sgt2_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_topf := (finance.fn_create_account('{"name":"__sgt2_topf__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_goal := (finance.fn_create_savings_goal(jsonb_build_object(
    'name','__sgt2_goal__','target_amount',500,'target_date',(current_date + 365)::text,
    'monthly_savings_rate',50,'account_id',v_giro,'reserve_account_id',v_topf,
    'schedule_day_of_month',1,'first_payment_date',current_date::text))->>'goal_id')::int;

  v_res := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_giro,
    'to_account_id',v_topf,'amount',500,'direction','deposit'));
  IF v_res->'savings_goal_reached'->>'note' NOT LIKE '%" reached (%' THEN
    RAISE EXCEPTION 'FAIL [genau erreicht]: erwartet "reached" ohne "exceeded", got %', v_res; END IF;
  RAISE NOTICE 'PASS [genau erreicht = reached]';
END $$;

ROLLBACK;
