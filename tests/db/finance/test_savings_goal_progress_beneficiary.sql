-- tests/db/finance/test_savings_goal_progress_beneficiary.sql
-- Multi-Member WS-3b: finance.savings_goal_progress traegt jetzt beneficiary_person_id
-- (beguenstigte Person je Ziel, Slug aus family; NULL = Haushalt). Macht den Pro-Kind-Ziel-
-- Fortschritt isolierbar (der Advisor schluesselt je beguenstigtem Kind auf). Die Spalte ist
-- grain-neutral: g.id ist PK -> beneficiary_person_id ist funktional von der Gruppierung abhaengig
-- -> weiterhin GENAU EINE Zeile je Ziel.
--
-- WICHTIG (orthogonale Dimensionen): die View leitet current_amount jetzt LEDGER-basiert ab
-- (Summe gebuchter Beitraege per recurring_payment_id, WS-1) und hat KEINE Konto-Owner-Spalte. Ein
-- kind-beguenstigtes Ziel, dessen Beitraege ueber ein ELTERN-Konto laufen ("reserviert-aber-Eltern-
-- besessen", Custodial-Fall), zaehlt am Ziel (beneficiary=Kind) — der Fortschritt haengt am Ziel-rp,
-- NICHT am finanzierenden Konto.
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_res        JSONB;
  v_kid_goal   INT;
  v_kid_rp     INT;
  v_hh_goal    INT;
  v_parent_acct INT;
  v_beneficiary TEXT;
  v_current    NUMERIC;
  v_remaining  NUMERIC;
  v_progress   NUMERIC;
  v_rowcount   INT;
BEGIN
  -- ---------- Person (projiziertes Read-Model; im Test direkt befuellt) ----------
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('sgp_kid', 'Kind Beispiel', 'child');

  -- ---------- Eltern-Konto (owner NULL = Haushalt/Eltern), finanziert das Kind-Ziel ----------
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__sgp_parent_cash__','cash','EUR','active', NULL) RETURNING id INTO v_parent_acct;
  UPDATE finance.account_balances SET balance = 5000 WHERE account_id = v_parent_acct;

  -- ---------- Ziel 1: kind-beguenstigt, Reserve-Zufluss 1500 (markiert) ueber das ELTERN-Konto ----------
  -- target 3000, markierter Reserve-Zufluss 1500 -> current 1500, remaining 1500, progress 50 %.
  -- WS-A: Fortschritt = markierte Bewegungen (savings_goal_id), konto-owner-unabhaengig (haengt am Ziel).
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__sgp_kid_goal__','target_amount',3000,'target_date',(current_date + 365)::text,
    'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_parent_acct,'schedule_day_of_month',1,'first_payment_date',(current_date - 30)::text,
    'beneficiary_person_id','sgp_kid')) INTO v_res;
  v_kid_goal := (v_res->>'goal_id')::int;
  v_kid_rp   := (v_res->>'recurring_payment_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_parent_acct, 1500, current_date - 15, 'transfer', v_kid_goal, gen_random_uuid());

  -- ---------- Ziel 2: ohne Beguenstigten (Haushalt), keine Beitraege ----------
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, beneficiary_person_id)
    VALUES ('__sgp_hh_goal__', 1000, current_date + 365, 'active', NULL)
    RETURNING id INTO v_hh_goal;

  -- ===== TEST 1: kind-beguenstigtes Ziel -> View gibt den Slug zurueck =====
  SELECT beneficiary_person_id INTO v_beneficiary
  FROM finance.savings_goal_progress WHERE id = v_kid_goal;
  IF v_beneficiary IS DISTINCT FROM 'sgp_kid' THEN
    RAISE EXCEPTION 'FAIL [beneficiary slug]: erwartet sgp_kid, got %', v_beneficiary; END IF;
  RAISE NOTICE 'PASS [kind-beguenstigtes Ziel -> beneficiary_person_id = sgp_kid]';

  -- ===== TEST 2: Ziel ohne Beguenstigten -> NULL (Haushalt) =====
  SELECT beneficiary_person_id INTO v_beneficiary
  FROM finance.savings_goal_progress WHERE id = v_hh_goal;
  IF v_beneficiary IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [no beneficiary]: erwartet NULL (Haushalt), got %', v_beneficiary; END IF;
  RAISE NOTICE 'PASS [Ziel ohne Beguenstigten -> beneficiary_person_id IS NULL]';

  -- ===== TEST 3: Edge — Kind-Ziel ueber ELTERN-Konto: Fortschritt haengt am Ziel-rp, nicht am Konto =====
  -- current_amount = Summe gebuchter Beitraege (1500) UNABHAENGIG vom finanzierenden Konto (Eltern-Konto).
  -- Die View hat keine Konto-Owner-Spalte -> beide Dimensionen orthogonal (reserviert-aber-Eltern-besessen).
  SELECT current_amount, remaining_amount, progress_percent INTO v_current, v_remaining, v_progress
  FROM finance.savings_goal_progress WHERE id = v_kid_goal;
  IF v_current IS DISTINCT FROM 1500 THEN
    RAISE EXCEPTION 'FAIL [edge current_amount]: erwartet 1500 (Beitrag ueber Eltern-Konto zaehlt am Kind-Ziel), got %', v_current; END IF;
  IF v_remaining IS DISTINCT FROM 1500 THEN
    RAISE EXCEPTION 'FAIL [edge remaining_amount]: erwartet 1500 (3000-1500), got %', v_remaining; END IF;
  IF v_progress IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'FAIL [edge progress_percent]: erwartet 50, got %', v_progress; END IF;
  RAISE NOTICE 'PASS [Kind-Ziel auf Eltern-Konto: current=1500, remaining=1500, progress=50%% (Ziel-bezogen, konto-owner-unabhaengig)]';

  -- ===== TEST 4: Grain-Pin — genau EINE Zeile je Ziel trotz neuer GROUP-BY-Spalte =====
  SELECT count(*) INTO v_rowcount FROM finance.savings_goal_progress WHERE id = v_kid_goal;
  IF v_rowcount IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL [grain]: erwartet genau 1 Zeile je Ziel, got %', v_rowcount; END IF;
  RAISE NOTICE 'PASS [Grain: genau 1 Zeile je Ziel (beneficiary_person_id funktional von g.id PK)]';
END $$;

ROLLBACK;
