-- tests/db/finance/test_fn_loan_balance_at.sql
-- fn_loan_balance_at = reine Restschuld-Vorschau (WP2 "Finanzen schlank", Anzeige "voraussichtlich, bei gleichem Zins,
-- ohne Sondertilgung"). Handgerechnet: 10.000 zu 6 % mit 500/Monat -> Zins 50,00 / 47,75 -> 9.550,00 / 9.097,75.
--   (1) zwei Raten ab dem ersten Termin = valid_from (Reviewer: der Termin AM valid_from zaehlt mit)
--   (2) Start nach dem letzten erledigten Termin (p_after): nur spaetere Raten
--   (3) Quartalsrate traegt drei Monatszinsen (wie fn_get_loan_payment_split)
--   (4) Split in der Zukunft: zwei Segmente, Betrag wechselt am Stichtag
--   (5) letzte kleinere Rate tilgt ganz -> 0, danach bleibt 0
--   (6) NULL: Ziel <= heute, keine Segmente, Iterationsdeckel
--   (7) IMMUTABLE
BEGIN;

DO $$
DECLARE
  v_seg jsonb := '[{"anchor":"2026-02-01","interval":1,"unit":"month","dom":1,"days":null,"valid_from":"2026-02-01","valid_to":null,"amount":500}]';
  v_val numeric;
BEGIN
  -- (1)
  v_val := finance.fn_loan_balance_at(10000, 6, v_seg, NULL, '2026-02-01', '2026-01-15');
  IF v_val IS DISTINCT FROM 9550.00 THEN RAISE EXCEPTION 'FAIL [1a]: %', v_val; END IF;
  v_val := finance.fn_loan_balance_at(10000, 6, v_seg, NULL, '2026-03-15', '2026-01-15');
  IF v_val IS DISTINCT FROM 9097.75 THEN RAISE EXCEPTION 'FAIL [1b]: %', v_val; END IF;

  -- (2) Februar-Rate schon gebucht (Restschuld 9.550 heute) -> nur die Maerz-Rate
  v_val := finance.fn_loan_balance_at(9550, 6, v_seg, '2026-02-01', '2026-03-15', '2026-02-10');
  IF v_val IS DISTINCT FROM 9097.75 THEN RAISE EXCEPTION 'FAIL [2]: %', v_val; END IF;

  -- (3) Quartal: 10.000 * 6 % / 12 * 3 = 150 Zins, 1.500 Rate -> 1.350 Tilgung -> 8.650
  v_val := finance.fn_loan_balance_at(10000, 6,
    '[{"anchor":"2026-03-31","interval":3,"unit":"month","dom":-1,"days":null,"valid_from":"2026-01-01","valid_to":null,"amount":1500}]',
    NULL, '2026-04-30', '2026-01-15');
  IF v_val IS DISTINCT FROM 8650.00 THEN RAISE EXCEPTION 'FAIL [3]: %', v_val; END IF;

  -- (4) 500 bis 01.03. exklusiv, ab 01.03. 1.000: Feb 9.550 -> Mar Zins 47,75 Tilgung 952,25 -> 8.597,75
  v_val := finance.fn_loan_balance_at(10000, 6,
    '[{"anchor":"2026-02-01","interval":1,"unit":"month","dom":1,"days":null,"valid_from":"2026-02-01","valid_to":"2026-03-01","amount":500},
      {"anchor":"2026-02-01","interval":1,"unit":"month","dom":1,"days":null,"valid_from":"2026-03-01","valid_to":null,"amount":1000}]',
    NULL, '2026-03-01', '2026-01-15');
  IF v_val IS DISTINCT FROM 8597.75 THEN RAISE EXCEPTION 'FAIL [4]: %', v_val; END IF;

  -- (5) Restschuld 300 zu 6 %, Rate 500 -> ganz getilgt
  v_val := finance.fn_loan_balance_at(300, 6, v_seg, NULL, '2026-12-31', '2026-01-15');
  IF v_val IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [5]: %', v_val; END IF;

  -- (6)
  IF finance.fn_loan_balance_at(10000, 6, v_seg, NULL, '2026-01-15', '2026-01-15') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [6 target<=today]'; END IF;
  IF finance.fn_loan_balance_at(10000, 6, '[]', NULL, '2027-01-15', '2026-01-15') IS NOT NULL
     OR finance.fn_loan_balance_at(10000, 6, NULL, NULL, '2027-01-15', '2026-01-15') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [6 no segments]'; END IF;
  -- taegliche Mini-Rate ueber 10 Jahre (> 2.400 Termine) -> Deckel -> NULL
  IF finance.fn_loan_balance_at(1000000, 1,
       '[{"anchor":"2026-02-01","interval":1,"unit":"day","dom":null,"days":null,"valid_from":"2026-02-01","valid_to":null,"amount":30}]',
       NULL, '2036-02-01', '2026-01-15') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [6 cap]'; END IF;

  -- (7)
  IF (SELECT provolatile FROM pg_proc
      WHERE oid = 'finance.fn_loan_balance_at(numeric,numeric,jsonb,date,date,date)'::regprocedure) <> 'i' THEN
    RAISE EXCEPTION 'FAIL [7 volatility]'; END IF;

  RAISE NOTICE 'PASS fn_loan_balance_at (handgerechnet, Start nach Buchung, Quartal, Split, Abloese, NULL-Faelle, IMMUTABLE)';
END $$;

ROLLBACK;
