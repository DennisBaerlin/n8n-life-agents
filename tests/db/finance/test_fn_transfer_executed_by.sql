-- tests/db/finance/test_fn_transfer_executed_by.sql
-- Wer fuehrt einen wiederkehrenden Uebertrag aus (Dauerauftrag bei der Bank oder
--   ueberweist der Nutzer selbst)? Die Spalte recurring_payments.executed_by ist eine reine Nutzerangabe (NULL = nicht
--   angegeben), die eine Regel steckt in finance.fn_transfer_executed_by(rp_id): gespeichert gewinnt, sonst Quelle
--   Geld-Konto (cash) -> 'unknown', jede andere Kontoart (P2P, Depot, Festgeld, Kredit) -> 'manual' (dort kann keine
--   Dauerauftrags-Regel liegen), Zeile ohne Ziel-Konto -> 'unknown'. CHECKs: nur 'bank'|'manual', nur an Uebertraegen.
--   Werte erfunden.
BEGIN;
DO $$
DECLARE
  v_cash INT; v_cash2 INT; v_p2p INT; v_fix INT; v_depot INT; v_loan INT;
  v_rp_cash INT; v_rp_p2p INT; v_rp_fix INT; v_rp_depot INT; v_rp_loan INT; v_rp_plain INT;
  v_caught BOOLEAN;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_xb_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_xb_cash2__','cash','EUR','active') RETURNING id INTO v_cash2;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_xb_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date)
    VALUES ('__t_xb_fix__','fixed_deposit','EUR','active', current_date + 365) RETURNING id INTO v_fix;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__t_xb_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_xb_loan__','loan','EUR','active') RETURNING id INTO v_loan;

  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_xb_cash_t__', v_cash, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_cash;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_xb_p2p_t__', v_p2p, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_p2p;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_xb_fix_t__', v_fix, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_fix;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_xb_depot_t__', v_depot, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_depot;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_xb_loan_t__', v_loan, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_loan;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_xb_plain__', v_cash, -30, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_plain;

  -- [1] Standard ohne Angabe: Geld-Konto -> unknown; P2P/Festgeld/Depot/Kredit -> manual; kein Ziel -> unknown
  IF finance.fn_transfer_executed_by(v_rp_cash)  IS DISTINCT FROM 'unknown'
     OR finance.fn_transfer_executed_by(v_rp_p2p)   IS DISTINCT FROM 'manual'
     OR finance.fn_transfer_executed_by(v_rp_fix)   IS DISTINCT FROM 'manual'
     OR finance.fn_transfer_executed_by(v_rp_depot) IS DISTINCT FROM 'manual'
     OR finance.fn_transfer_executed_by(v_rp_loan)  IS DISTINCT FROM 'manual'
     OR finance.fn_transfer_executed_by(v_rp_plain) IS DISTINCT FROM 'unknown'
     OR finance.fn_transfer_executed_by(-1)         IS DISTINCT FROM 'unknown' THEN
    RAISE EXCEPTION 'FAIL [1] Standard je Kontoart: cash=% p2p=% fix=% depot=% loan=% plain=% unbekannt=%',
      finance.fn_transfer_executed_by(v_rp_cash), finance.fn_transfer_executed_by(v_rp_p2p), finance.fn_transfer_executed_by(v_rp_fix),
      finance.fn_transfer_executed_by(v_rp_depot), finance.fn_transfer_executed_by(v_rp_loan),
      finance.fn_transfer_executed_by(v_rp_plain), finance.fn_transfer_executed_by(-1); END IF;
  RAISE NOTICE 'PASS [1] ohne Angabe: Geld-Konto unknown, P2P/Festgeld/Depot/Kredit manual, kein Ziel unknown';

  -- [2] gespeicherter Wert gewinnt ueber den Standard (bank auf P2P, manual auf Geld-Konto)
  UPDATE finance.recurring_payments SET executed_by = 'bank'   WHERE id = v_rp_p2p;
  UPDATE finance.recurring_payments SET executed_by = 'manual' WHERE id = v_rp_cash;
  IF finance.fn_transfer_executed_by(v_rp_p2p)  IS DISTINCT FROM 'bank'
     OR finance.fn_transfer_executed_by(v_rp_cash) IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'FAIL [2] gespeichert gewinnt: p2p=% cash=%',
      finance.fn_transfer_executed_by(v_rp_p2p), finance.fn_transfer_executed_by(v_rp_cash); END IF;
  RAISE NOTICE 'PASS [2] gespeicherter Wert gewinnt';

  -- [3] CHECK: nur bank|manual
  v_caught := false;
  BEGIN
    UPDATE finance.recurring_payments SET executed_by = 'auto' WHERE id = v_rp_cash;
  EXCEPTION WHEN check_violation THEN v_caught := true; END;
  IF NOT v_caught THEN RAISE EXCEPTION 'FAIL [3] Wert auto haette abgelehnt werden muessen'; END IF;
  -- CHECK: nur an Uebertraegen (Zeile ohne Ziel-Konto)
  v_caught := false;
  BEGIN
    UPDATE finance.recurring_payments SET executed_by = 'bank' WHERE id = v_rp_plain;
  EXCEPTION WHEN check_violation THEN v_caught := true; END;
  IF NOT v_caught THEN RAISE EXCEPTION 'FAIL [3b] executed_by an einer Zeile ohne Ziel haette abgelehnt werden muessen'; END IF;
  RAISE NOTICE 'PASS [3] CHECKs: nur bank|manual, nur an Uebertraegen';
END $$;
ROLLBACK;
