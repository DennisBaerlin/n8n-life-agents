-- tests/db/finance/test_fn_name_matches.sql
-- Namens-Aufloesung "erst exakt, nur bei 0 Treffern ohne Gross-/Kleinschreibung + getrimmt" (Paket DB-ist-das-Gesetz S3):
--   (1) finance.fn_name_matches: exakt-Modus vs. ci-Modus.
--   (2) fn_resolve_account: "dkb giro " findet "DKB Giro" (ci-Pass); ein Bestandspaar "Tagesgeld"/"tagesgeld" bleibt bei
--       exakter Eingabe eindeutig (keine neue Mehrdeutigkeit), nur eine dritte Schreibweise ist mehrdeutig (2 Treffer).
--   (3) fn_resolve_loan (zweistufig: Zaehlen + Zeile holen) liefert im ci-Pass die Kredit-IDs.
BEGIN;

DO $$
DECLARE
  v_res jsonb; v_a1 int; v_id int; v_hits int; v_debit int; v_loan int;
BEGIN
  IF NOT finance.fn_name_matches('DKB Giro', 'DKB Giro', true) OR finance.fn_name_matches('DKB Giro', 'dkb giro', true)
     OR NOT finance.fn_name_matches('DKB Giro', ' dkb giro ', false) OR finance.fn_name_matches('DKB Giro', 'DKB', false) THEN
    RAISE EXCEPTION 'FAIL fn_name_matches [exakt/ci]'; END IF;

  v_a1 := (finance.fn_create_account('{"name":"__nm DKB Giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  SELECT id, hit_count INTO v_id, v_hits FROM finance.fn_resolve_account(' __nm dkb giro__ ');
  IF v_hits IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_a1 THEN
    RAISE EXCEPTION 'FAIL resolve_account [ci-Pass]: hits=% id=%', v_hits, v_id; END IF;

  PERFORM finance.fn_create_account('{"name":"__nm Tagesgeld__","account_type":"cash"}'::jsonb);
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__nm tagesgeld__', 'cash', 'EUR', 'active');   -- Bestandspaar (vor der ci-Namenssperre entstanden)
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_account('__nm Tagesgeld__');
  IF v_hits IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL resolve_account [exakt bleibt eindeutig]: hits=%', v_hits; END IF;
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_account('__NM TAGESGELD__');
  IF v_hits IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL resolve_account [dritte Schreibweise mehrdeutig]: hits=%', v_hits; END IF;

  v_debit := (finance.fn_create_account('{"name":"__nm_debit__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_loan(jsonb_build_object(
    'name','__nm Hauskredit__','lender','TestBank','original_amount','100000',
    'disbursement_date','2024-01-01','interest_rate','3','principal_rate','1',
    'monthly_annuity','500','schedule_day_of_month','1','first_payment_date','2024-02-01','debit_account_id', v_debit));
  SELECT loan_id, hit_count INTO v_loan, v_hits FROM finance.fn_resolve_loan('__nm hauskredit__');
  IF v_hits IS DISTINCT FROM 1 OR v_loan IS NULL THEN
    RAISE EXCEPTION 'FAIL resolve_loan [ci-Pass]: hits=% id=%', v_hits, v_loan; END IF;

  RAISE NOTICE 'PASS Namens-Aufloesung [fn_name_matches, account ci + Bestandspaar, loan ci]';
END $$;

ROLLBACK;
