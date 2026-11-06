-- tests/db/finance/test_parent_cashflow.sql
-- Multi-Member WS-3a (D2 — Custodial off-budget): finance.parent_cashflow_overview/_summary.
-- Eltern-Scope-Cashflow — ein Eltern->Kind-Transfer zaehlt hier als AUSGABE (Geld verlaesst das
-- Eltern-Budget), waehrend die Gesamt-Familie-Sicht (monthly_cashflow_overview) ihn neutral laesst.
-- Erkennung AUSSCHLIESSLICH ueber die Owner-Rolle des Zielkontos (owner_person_id->role='child' via
-- core.fn_household_persons()), NIE ueber Text. Doppelzaehl-Schutz: Kind-besessene Recurring (Kind-
-- Sparplan) faellt im Eltern-Scope raus -> kein -X-Doppelzaehlen (Familie-Scope = Kind-Sparplan,
-- Eltern-Scope = Eltern->Kind-Transfer). WS-2 own<->own-Neutralitaet bleibt unangetastet.
BEGIN;

DO $$
DECLARE
  v_p_cash INT; v_p_cash2 INT; v_kid_cash INT; v_parent_owned INT;
  v_in_parent INT; v_in_family INT;
  v_pc_income NUMERIC; v_pc_expense NUMERIC; v_pc_net NUMERIC;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('pcf_kid', 'Kind', 'child'), ('pcf_parent', 'Elternteil', 'owner');

  -- Haushalts-Konten (owner NULL) + Kind-Konto (owner child) + Eltern-PERSON-Konto (owner parent)
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__pcf_p_cash__','cash','EUR','active', NULL) RETURNING id INTO v_p_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__pcf_p_cash2__','cash','EUR','active', NULL) RETURNING id INTO v_p_cash2;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__pcf_kid_cash__','cash','EUR','active', 'pcf_kid') RETURNING id INTO v_kid_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__pcf_parent_owned__','cash','EUR','active', 'pcf_parent') RETURNING id INTO v_parent_owned;

  -- rp1: Eltern->Kind-Transfer (Quelle Eltern, Ziel Kind), amount -200 (Quell-Sicht negativ)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pcf_top_up_kid__', v_p_cash, v_kid_cash, -200, 1, 'month', current_date, current_date, 'active');
  -- rp2: own<->own Eltern-Transfer (Quelle+Ziel Eltern), amount -150 -> NEUTRAL in BEIDEN Scopes
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pcf_own_transfer__', v_p_cash, v_p_cash2, -150, 1, 'month', current_date, current_date, 'active');
  -- rp3: Kind-Sparplan (Quelle Kind, kein Ziel), amount -300 -> Eltern-Scope RAUS, Familie-Scope DRIN
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pcf_kid_savings__', v_kid_cash, -300, 1, 'month', current_date, current_date, 'active');
  -- rp4: normale Eltern-Ausgabe (Quelle Eltern, kein Ziel), amount -100
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pcf_parent_expense__', v_p_cash, -100, 1, 'month', current_date, current_date, 'active');
  -- rp5: Eltern-Einnahme (Quelle Eltern, kein Ziel), amount +500
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pcf_parent_income__', v_p_cash, 500, 1, 'month', current_date, current_date, 'active');
  -- rp6: Eltern-PERSON-Konto -> Haushalts-Konto (beide Nicht-Kind), amount -80 -> NEUTRAL (Ziel nicht child)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pcf_parent_to_household__', v_parent_owned, v_p_cash, -80, 1, 'month', current_date, current_date, 'active');

  -- ===== Eltern-Scope: Transfer-an-Kind + normale Eltern-rp; KEIN own<->own, KEIN Kind-Sparplan =====
  SELECT count(*) INTO v_in_parent FROM finance.parent_cashflow_overview
   WHERE name = ANY(ARRAY['__pcf_top_up_kid__','__pcf_parent_expense__','__pcf_parent_income__']);
  IF v_in_parent <> 3 THEN RAISE EXCEPTION 'FAIL [parent incl]: erwartet 3 Eltern-Zeilen (Transfer-Kind + Ausgabe + Einnahme), got %', v_in_parent; END IF;

  IF EXISTS (SELECT 1 FROM finance.parent_cashflow_overview WHERE name = '__pcf_own_transfer__') THEN
    RAISE EXCEPTION 'FAIL [parent own-transfer]: own<->own Eltern-Transfer darf NICHT im Eltern-Scope sein (neutral)'; END IF;
  IF EXISTS (SELECT 1 FROM finance.parent_cashflow_overview WHERE name = '__pcf_kid_savings__') THEN
    RAISE EXCEPTION 'FAIL [parent kid-savings]: Kind-besessener Sparplan darf NICHT im Eltern-Scope sein (Kind-Owner)'; END IF;
  -- Eltern-Person-Konto -> Haushalts-Konto: Ziel ist NICHT child -> neutral (raus), wie jeder Nicht-Kind-Transfer
  IF EXISTS (SELECT 1 FROM finance.parent_cashflow_overview WHERE name = '__pcf_parent_to_household__') THEN
    RAISE EXCEPTION 'FAIL [parent->household]: Transfer aufs Haushalts-Konto (Ziel nicht child) darf NICHT im Eltern-Scope zaehlen'; END IF;
  RAISE NOTICE 'PASS [Eltern-Scope: Eltern->Kind-Transfer + Eltern-rp; own<->own + Kind-Sparplan + Eltern->Haushalt raus]';

  -- ===== Eltern-Scope-Summary: income 500 / Konsum -300 (Transfer 200 + Ausgabe 100) / frei = Konto 200 =====
  -- Audit Paket 3: gleiche Spalten wie monthly_cashflow_summary (Konsum/Pflicht/frei/Sparen/Kontoveraenderung).
  SELECT monthly_income, monthly_consumption, monthly_account_change INTO v_pc_income, v_pc_expense, v_pc_net
    FROM finance.parent_cashflow_summary;
  IF v_pc_income IS DISTINCT FROM 500 THEN RAISE EXCEPTION 'FAIL [parent income]: erwartet 500, got %', v_pc_income; END IF;
  IF v_pc_expense IS DISTINCT FROM -300 THEN RAISE EXCEPTION 'FAIL [parent consumption]: erwartet -300 (Transfer 200 + Ausgabe 100), got %', v_pc_expense; END IF;
  IF v_pc_net IS DISTINCT FROM 200 THEN RAISE EXCEPTION 'FAIL [parent account_change]: erwartet 200, got %', v_pc_net; END IF;
  RAISE NOTICE 'PASS [Eltern-Scope-Summary: +500 / Konsum -300 / Konto 200 (Transfer-an-Kind als Konsum)]';

  -- ===== Gesamt-Familie-Sicht UNVERAENDERT: beide Transfers raus, Kind-Sparplan DRIN (Doppelzaehl-Schutz) =====
  SELECT count(*) INTO v_in_family FROM finance.monthly_cashflow_overview
   WHERE name = ANY(ARRAY['__pcf_kid_savings__','__pcf_parent_expense__','__pcf_parent_income__']);
  IF v_in_family <> 3 THEN RAISE EXCEPTION 'FAIL [family incl]: erwartet 3 Familie-Zeilen (Kind-Sparplan + Eltern-Ausgabe + Einnahme), got %', v_in_family; END IF;
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE name IN ('__pcf_top_up_kid__','__pcf_own_transfer__')) THEN
    RAISE EXCEPTION 'FAIL [family transfers]: Transfers (target gesetzt) duerfen NICHT in der Familie-Sicht zaehlen (WS-2)'; END IF;
  RAISE NOTICE 'PASS [Familie-Sicht unveraendert: Transfers raus, Kind-Sparplan drin -> kein -200-Doppelzaehlen]';
END $$;

ROLLBACK;
