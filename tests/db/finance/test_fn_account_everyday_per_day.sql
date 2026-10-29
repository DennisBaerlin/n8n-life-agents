-- tests/db/finance/test_fn_account_everyday_per_day.sql
-- finance.fn_account_everyday_per_day(acct) — Alltagsausgaben je Tag aus den letzten 3 Auszuegen (Rundung 2):
--   per_day = nur Abgaenge (Kontovorschau), per_day_net = Abgaenge + nicht zugeordnete Eingaenge, hoechstens 0
--   (Spar-Deckung), has_history. Nenner = neu abgeglichene Tage. Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; r record;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ed_a__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  SELECT * INTO r FROM finance.fn_account_everyday_per_day(v_a);
  IF r.per_day <> 0 OR r.per_day_net <> 0 OR r.has_history THEN RAISE EXCEPTION 'FAIL [1] ohne Auszug 0/0/false, got %', r; END IF;

  -- 30 neue Tage: -300 raus, +60 rein -> per_day -10, netto -8
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_a, t - 34, t - 5, 1300, 1060, 'EUR', 5, 0, -300, 60, NULL);
  SELECT * INTO r FROM finance.fn_account_everyday_per_day(v_a);
  IF r.per_day IS DISTINCT FROM -10.00::numeric OR r.per_day_net IS DISTINCT FROM -8.00::numeric OR NOT r.has_history THEN
    RAISE EXCEPTION 'FAIL [2] -10 / netto -8, got %', r; END IF;

  -- mehr nicht zugeordnete Eingaenge als Abgaenge -> netto 0 (blaeht die Deckung nie auf)
  UPDATE finance.bank_statements SET unmatched_in = 900 WHERE account_id = v_a;
  SELECT * INTO r FROM finance.fn_account_everyday_per_day(v_a);
  IF r.per_day_net <> 0 THEN RAISE EXCEPTION 'FAIL [3] netto hoechstens 0, got %', r; END IF;
  RAISE NOTICE 'PASS fn_account_everyday_per_day: ohne Auszug 0, per_day / per_day_net, netto gedeckelt';
END $$;
ROLLBACK;
