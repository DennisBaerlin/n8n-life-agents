-- tests/db/finance/test_fn_goal_transfer_candidates.sql
-- Testet finance.fn_goal_transfer_candidates: freistehende Dauerauftraege in einen Sparziel-Topf (Livebefund
--   2026-10-27: ein bestehender Uebertrag wurde geloescht und als Ziel-Rate ohne Tag neu angelegt).
BEGIN;

DO $$
DECLARE
  v_r      JSONB;
  v_from   INT;
  v_other  INT;
  v_pot    INT;
  v_next1  DATE := (date_trunc('month', current_date) + interval '1 month')::date;  -- der 1. des Folgemonats
  v_goal_rp INT;
  v_c      JSONB;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_gtc_from__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_from;
  SELECT (finance.fn_create_account('{"name":"__test_gtc_other__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_other;
  SELECT (finance.fn_create_account('{"name":"__test_gtc_pot__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_pot;

  -- Ziel-eigene Rate in denselben Topf (gehoert einer Entitaet -> nie Kandidat)
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__test_gtc_goal__','target_amount',1200,
           'monthly_savings_rate',100,'account_id',v_other,'reserve_account_id',v_pot,'schedule_day_of_month',15));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL goal: %', v_r; END IF;
  v_goal_rp := (v_r->>'recurring_payment_id')::int;

  -- freistehender Monats-Dauerauftrag am 1. (Start kuenftig) -> Kandidat, ersetzbar
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__test_gtc_monthly__','from_account_id',v_from,
           'to_account_id',v_pot,'amount',150,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',v_next1));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL monthly: %', v_r; END IF;
  -- quartalsweise vom anderen Konto -> Kandidat, nicht ersetzbar
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__test_gtc_quarterly__','from_account_id',v_other,
           'to_account_id',v_pot,'amount',300,'schedule_unit','month','schedule_interval',3,'schedule_day_of_month',5,
           'first_payment_date',(v_next1 + 4)));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL quarterly: %', v_r; END IF;
  -- beendeter Dauerauftrag -> nie Kandidat
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
         schedule_day_of_month, first_payment_date, valid_from, valid_to, status)
  VALUES ('__test_gtc_ended__', v_from, v_pot, -80, 1, 'month', 3, current_date - 90, current_date - 90, current_date - 1, 'active');

  v_r := finance.fn_goal_transfer_candidates(v_pot, NULL);
  IF jsonb_array_length(v_r) <> 2 THEN
    RAISE EXCEPTION 'FAIL fn_goal_transfer_candidates [alle]: erwartet 2, got %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r) e WHERE (e->>'id')::int = v_goal_rp) THEN
    RAISE EXCEPTION 'FAIL fn_goal_transfer_candidates: Ziel-eigene Rate als Kandidat'; END IF;
  RAISE NOTICE 'PASS fn_goal_transfer_candidates [freistehend ja, Ziel-eigen/beendet nein]';

  v_r := finance.fn_goal_transfer_candidates(v_pot, v_from);
  IF jsonb_array_length(v_r) <> 1 THEN RAISE EXCEPTION 'FAIL fn_goal_transfer_candidates [Kontofilter]: %', v_r; END IF;
  v_c := v_r->0;
  IF v_c->>'name' IS DISTINCT FROM '__test_gtc_monthly__' OR (v_c->>'amount')::numeric <> 150.00
     OR (v_c->>'monthly_amount')::numeric <> 150.00 OR (v_c->>'day')::int <> 1
     OR (v_c->>'replaceable')::boolean IS DISTINCT FROM true OR (v_c->>'next_due')::date IS DISTINCT FROM v_next1
     OR (v_c->>'account_id')::int <> v_from OR v_c->>'rhythm' IS DISTINCT FROM 'monthly, on day 1' THEN
    RAISE EXCEPTION 'FAIL fn_goal_transfer_candidates [Felder]: %', v_c; END IF;
  RAISE NOTICE 'PASS fn_goal_transfer_candidates [Kontofilter + Felder: Betrag, Tag, ersetzbar, naechster Termin]';

  v_r := finance.fn_goal_transfer_candidates(v_pot, v_other);
  IF jsonb_array_length(v_r) <> 1 OR (v_r->0->>'replaceable')::boolean IS DISTINCT FROM false
     OR (v_r->0->>'monthly_amount')::numeric <> 100.00 THEN
    RAISE EXCEPTION 'FAIL fn_goal_transfer_candidates [quartalsweise]: %', v_r; END IF;
  RAISE NOTICE 'PASS fn_goal_transfer_candidates [quartalsweise -> nicht ersetzbar, Monatsbetrag]';
END $$;

ROLLBACK;
