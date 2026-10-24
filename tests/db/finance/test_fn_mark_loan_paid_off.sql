-- tests/db/finance/test_fn_mark_loan_paid_off.sql
-- Audit Paket 2, Punkt 9: letzte Kreditrate + Restschuld 0 -> abbezahlt, und der Storno stellt zurueck.
--   Kredit Restschuld 800, 3 % p.a., Annuitaet 500, monatlich ab d0.
--   Rate d0: Zins 2.00, Tilgung 498 -> Rest 302.
--   Rate d1: Annuitaet 500 wuerde ueberzahlen (Tilgung 499.24 > 302) -> vorher lehnte die Erinnerung ab, ohne Grund.
--     Jetzt: fn_recurring_occurrence_amount = -302.76 (Rest 302 + Zins 0.76), die Erinnerung bucht genau das ->
--     Rest 0 -> Kredit paid_off, Raten-rp paused + valid_to = d1 + 1 (vorher blieb active, die Erinnerung fragte weiter).
--   Storno der letzten Rate -> Kredit wieder active, Rate laeuft wieder (valid_to NULL).
--   Storno einer FRUEHEREN Rate nach der Abzahlung -> ebenfalls zurueck auf active.
--   Ein Nutzer-Betrag (Override) ueber der Abloese bleibt {ok:false} (nie still geaendert).
BEGIN;

DO $$
DECLARE
  v_res  JSONB;
  v_giro INT;
  v_loan INT;
  v_lacc INT;
  v_rp   INT;
  v_d0   DATE := CURRENT_DATE - 40;
  v_d1   DATE;
  v_tx0  INT;
  v_tx1  INT;
BEGIN
  v_d1 := (v_d0 + interval '1 month')::date;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_mlp_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_giro;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_mlp_kredit__','lender','B','borrower','T',
    'original_amount',10000,'current_balance',800,'disbursement_date',(v_d0 - 30)::text,'interest_rate',3,
    'monthly_annuity',500,'first_payment_date',v_d0::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;
  SELECT recurring_payment_id INTO v_rp FROM finance.loans WHERE id = v_loan;
  IF finance.fn_get_balance(v_lacc) IS DISTINCT FROM -800.00 THEN
    RAISE EXCEPTION 'SETUP FAIL Restschuld: %', finance.fn_get_balance(v_lacc); END IF;

  -- regulaere Rate d0
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_d0::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM -302.00 THEN
    RAISE EXCEPTION 'SETUP FAIL Rate d0: % Rest=%', v_res, finance.fn_get_balance(v_lacc); END IF;
  v_tx0 := (v_res->>'transaction_id')::int;

  -- 1. Erinnerung zeigt den Abloesebetrag (eine Quelle mit der Buchung)
  IF finance.fn_recurring_occurrence_amount(v_rp, v_d1) IS DISTINCT FROM -302.76 THEN
    RAISE EXCEPTION 'FAIL letzte Rate [Betrag Erinnerung]: erwartet -302.76, got %', finance.fn_recurring_occurrence_amount(v_rp, v_d1); END IF;
  -- normale rp ohne Kredit: geplanter Betrag; unbekannte rp: NULL
  IF finance.fn_recurring_occurrence_amount(-1, v_d1) IS NOT NULL THEN RAISE EXCEPTION 'FAIL occurrence_amount [unbekannt]'; END IF;
  RAISE NOTICE 'PASS letzte Rate [Erinnerung zeigt 302.76 = Rest 302 + Zins 0.76]';

  -- 2. Override ueber der Abloese bleibt ok:false (Nutzer-Betrag wird nie still geaendert)
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_d1::text,
    'amount', 500)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'payoff_amount')::numeric IS DISTINCT FROM 302.76 THEN
    RAISE EXCEPTION 'FAIL letzte Rate [Override]: erwartet ok:false mit payoff 302.76, got %', v_res; END IF;
  RAISE NOTICE 'PASS letzte Rate [Override 500 -> ok:false, payoff_amount 302.76]';

  -- 3. Erinnerung bucht die letzte Rate -> Rest 0, paid_off, Rate endet
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_d1::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->>'amount')::numeric IS DISTINCT FROM -302.76
     OR (v_res->>'remaining_debt')::numeric IS DISTINCT FROM 0
     OR v_res->>'loan_status' IS DISTINCT FROM 'paid_off' THEN
    RAISE EXCEPTION 'FAIL letzte Rate [Buchung]: %', v_res; END IF;
  v_tx1 := (v_res->>'transaction_id')::int;
  IF finance.fn_get_balance(v_lacc) IS DISTINCT FROM 0.00 OR finance.fn_get_balance(v_giro) IS DISTINCT FROM -802.76 THEN
    RAISE EXCEPTION 'FAIL letzte Rate [Salden]: Kredit=% Giro=%', finance.fn_get_balance(v_lacc), finance.fn_get_balance(v_giro); END IF;
  IF (SELECT status::text FROM finance.loans WHERE id = v_loan) IS DISTINCT FROM 'paid_off'
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp AND status = 'paused' AND valid_to = v_d1 + 1) THEN
    RAISE EXCEPTION 'FAIL abbezahlt [Status]: loan=% rp=%', (SELECT status FROM finance.loans WHERE id = v_loan),
      (SELECT to_jsonb(r) FROM finance.recurring_payments r WHERE id = v_rp); END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE + 60) o WHERE o.recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL abbezahlt [Erinnerung]: Rate weiter faellig'; END IF;
  RAISE NOTICE 'PASS abbezahlt [Rest 0 -> paid_off, Rate paused bis d1+1, keine weitere Erinnerung]';

  -- 4. Storno der letzten Rate -> Kredit + Rate zurueck
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx1)) INTO v_res;
  IF (SELECT status::text FROM finance.loans WHERE id = v_loan) IS DISTINCT FROM 'active'
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp AND status = 'active' AND valid_to IS NULL)
     OR (SELECT settled_from FROM finance.loans WHERE id = v_loan) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL storno letzte Rate: loan=% rp=% void=%', (SELECT status FROM finance.loans WHERE id = v_loan),
      (SELECT to_jsonb(r) FROM finance.recurring_payments r WHERE id = v_rp), v_res; END IF;
  RAISE NOTICE 'PASS storno [letzte Rate -> Kredit active, Rate laeuft wieder]';

  -- 5. erneut abzahlen, dann eine FRUEHERE Rate stornieren -> wieder Restschuld -> active
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_d1::text)) INTO v_res;
  IF v_res->>'loan_status' IS DISTINCT FROM 'paid_off' THEN RAISE EXCEPTION 'SETUP FAIL re-payoff: %', v_res; END IF;
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx0)) INTO v_res;
  IF (SELECT status::text FROM finance.loans WHERE id = v_loan) IS DISTINCT FROM 'active'
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp AND status = 'active' AND valid_to IS NULL)
     OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM -498.00 THEN
    RAISE EXCEPTION 'FAIL storno fruehere Rate: loan=% rp=% Rest=%', (SELECT status FROM finance.loans WHERE id = v_loan),
      (SELECT to_jsonb(r) FROM finance.recurring_payments r WHERE id = v_rp), finance.fn_get_balance(v_lacc); END IF;
  RAISE NOTICE 'PASS storno [fruehere Rate nach Abzahlung -> Kredit active, Rest 498]';
END $$;

-- Review: die letzte, kleinere Rate MANUELL im Chat bezahlt (tool_book_loan_payment, ohne due_date) wird ihrem
-- Vorkommen zugeordnet (Abloesebetrag = faellige Rate) -> Vorkommen geschlossen, Kredit abbezahlt, keine Erinnerung.
DO $$
DECLARE
  v_res  JSONB;
  v_giro INT;
  v_loan INT;
  v_lacc INT;
  v_rp   INT;
  v_d0   DATE := CURRENT_DATE - 40;
  v_d1   DATE;
BEGIN
  v_d1 := (v_d0 + interval '1 month')::date;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_mlp2_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_giro;
  -- frischer Kredit (Eroeffnung zum Auszahlungstag): ein laufender buchte seine Restschuld zum Stichtag heute, die
  -- vergangenen Raten d0/d1 steckten dann schon darin (fn_create_loan, Live-Befund 2026-10-24)
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_mlp2_kredit__','lender','B','borrower','T',
    'original_amount',800,'disbursement_date',(v_d0 - 30)::text,'interest_rate',3,
    'monthly_annuity',500,'first_payment_date',v_d0::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;
  SELECT recurring_payment_id INTO v_rp FROM finance.loans WHERE id = v_loan;
  PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_d0::text));

  v_res := finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,
    'debit_account_id',v_giro,'payment_amount',302.76,'payment_date',v_d1::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'matched_due_date')::date IS DISTINCT FROM v_d1
     OR v_res->>'loan_status' IS DISTINCT FROM 'paid_off' THEN
    RAISE EXCEPTION 'FAIL manuelle Abloese-Rate: erwartet Zuordnung % + paid_off, got %', v_d1, v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE + 60) o WHERE o.recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL manuelle Abloese-Rate: Vorkommen bleibt offen'; END IF;
  RAISE NOTICE 'PASS manuelle Abloese-Rate [zugeordnet, abbezahlt, keine Erinnerung]';
END $$;

ROLLBACK;
