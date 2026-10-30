-- tests/db/finance/test_fn_funding_accounts.sql
-- finance.fn_funding_accounts() — die EINE Regel, welche Konten eine Spar-Deckungs-Ampel haben (Seite Ziele + Karten-
--   Hinweis savings_funding): Abbuchungskonto eines aktiven Sparplans (Glied fn_recurring_current) oder Ziel eines
--   Dauerauftrags (fn_standing_orders kind transfer); nur aktive Nicht-Kredit-Konten. Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_kid INT; v_pause INT; v_closed INT; v_depot INT; v_rp INT;
  v_n INT;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('__fa_owner', 'Pat Muster', 'owner'), ('__fa_depot_owner', 'Alex Muster', 'partner'), ('__fa_kid', 'Kim Muster', 'child');
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__t_fa_giro__', 'cash', 'EUR', 'active', '__fa_owner') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fa_kid__', 'cash', 'EUR', 'active') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fa_pause__', 'cash', 'EUR', 'active') RETURNING id INTO v_pause;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fa_closed__', 'cash', 'EUR', 'closed') RETURNING id INTO v_closed;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__t_fa_depot__', 'stocks_depot', 'EUR', 'active', v_giro, '__fa_depot_owner') RETURNING id INTO v_depot;

  -- [a] aktiver Sparplan (erst kuenftig startend) -> Abbuchungskonto kind plan, mit Beguenstigtem + Depot-Inhaber
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('fa Plan Kind', v_kid, -50, 'month', t + 5, t + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id)
    VALUES ('fa Plan Kind', v_depot, 'FA1', 'Welt ETF', v_rp, '__fa_kid');
  SELECT count(*) INTO v_n FROM finance.fn_funding_accounts() f
   WHERE f.account_id = v_kid AND f.kind = 'plan' AND f.beneficiary_person_id = '__fa_kid'
     AND f.depot_owner_person_id = '__fa_depot_owner';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [a] Sparplan-Konto fehlt (n=%)', v_n; END IF;
  RAISE NOTICE 'PASS [a] Abbuchungskonto eines aktiven Sparplans';

  -- [b] pausierter Plan zaehlt nicht
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('fa Plan Pause', v_pause, -50, 'month', t + 5, t + 5, 'paused') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, status)
    VALUES ('fa Plan Pause', v_depot, 'FA2', 'Welt ETF', v_rp, 'paused');
  IF EXISTS (SELECT 1 FROM finance.fn_funding_accounts() f WHERE f.account_id = v_pause) THEN
    RAISE EXCEPTION 'FAIL [b] pausierter Plan zaehlt'; END IF;
  RAISE NOTICE 'PASS [b] nur aktive Plaene';

  -- [c] Ziel eines Dauerauftrags (kommend) -> kind transfer; die Quelle ist kein Deckungs-Konto
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('fa Uebertrag', v_giro, v_pause, -100, 'month', t + 1, t + 1);
  IF NOT EXISTS (SELECT 1 FROM finance.fn_funding_accounts() f WHERE f.account_id = v_pause AND f.kind = 'transfer')
     OR EXISTS (SELECT 1 FROM finance.fn_funding_accounts() f WHERE f.account_id = v_giro) THEN
    RAISE EXCEPTION 'FAIL [c] Dauerauftrags-Ziel'; END IF;
  RAISE NOTICE 'PASS [c] Ziel eines Dauerauftrags';

  -- [d] geschlossenes Konto als Ziel zaehlt nicht
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('fa Uebertrag zu', v_giro, v_closed, -100, 'month', t + 1, t + 1);
  IF EXISTS (SELECT 1 FROM finance.fn_funding_accounts() f WHERE f.account_id = v_closed) THEN
    RAISE EXCEPTION 'FAIL [d] geschlossenes Konto'; END IF;
  RAISE NOTICE 'PASS [d] nur aktive Konten';
END $$;
ROLLBACK;
