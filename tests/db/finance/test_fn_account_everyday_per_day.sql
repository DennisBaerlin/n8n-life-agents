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
  IF NOT r.provisional THEN RAISE EXCEPTION 'FAIL [3b] nur ein (der frueheste) Auszug -> provisional, got %', r; END IF;
  RAISE NOTICE 'PASS fn_account_everyday_per_day: ohne Auszug 0, per_day / per_day_net, netto gedeckelt';
END $$;

-- Transparenz 2026-10-30 (Live-Befund): der frueheste Auszug eines Kontos entsteht meist vor den Dauerauftraegen
-- ("Import zuerst") -> Gehalt/Uebertraege landen ungematcht im Alltag. Er zaehlt nicht mehr, sobald ein spaeterer da ist
-- (Rang nach period_end, auch wenn ein Chat-Abgleich davor prev_last_reconciled_at gesetzt hat); Fenster = 3 gezaehlte.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; r record; v_n INT;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ed_b__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  -- fruehester: 30 Tage, -3000 (100/Tag, eigentlich Gehalt + Uebertraege); prev gesetzt (Chat-Abgleich davor)
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_a, t - 124, t - 95, 5000, 2000, 'EUR', 9, 0, -3000, 0, t - 130),
         (v_a, t - 94,  t - 65, 2000, 1700, 'EUR', 5, 3, -300, 0, t - 95),
         (v_a, t - 64,  t - 35, 1700, 1100, 'EUR', 5, 3, -600, 0, t - 65),
         (v_a, t - 34,  t - 5,  1100,  800, 'EUR', 5, 3, -300, 0, t - 35);
  SELECT * INTO r FROM finance.fn_account_everyday_per_day(v_a);
  -- gezaehlt: die 3 juengsten (der frueheste faellt ohnehin raus) -> -1200 / 90 = -13.33
  IF r.per_day IS DISTINCT FROM -13.33::numeric OR r.provisional THEN
    RAISE EXCEPTION 'FAIL [4a] 3 juengste gezaehlt, fruehester raus: -13.33, got %', r; END IF;
  DELETE FROM finance.bank_statements WHERE account_id = v_a AND period_end IN (t - 65, t - 35);
  SELECT * INTO r FROM finance.fn_account_everyday_per_day(v_a);
  IF r.per_day IS DISTINCT FROM -10.00::numeric OR r.provisional THEN
    RAISE EXCEPTION 'FAIL [4b] fruehester + juengster: nur der juengste zaehlt (-10), got %', r; END IF;

  -- Details je Auszug (fn_account_everyday_basis): juengster zuerst, fruehester mit reason earliest
  SELECT count(*) INTO v_n FROM finance.fn_account_everyday_basis(v_a);
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [4c] 2 Zeilen erwartet, got %', v_n; END IF;
  SELECT * INTO r FROM finance.fn_account_everyday_basis(v_a) b ORDER BY b.period_end LIMIT 1;
  IF r.counted OR r.reason IS DISTINCT FROM 'earliest' OR r.per_day IS DISTINCT FROM -100.00::numeric OR r.days <> 30 THEN
    RAISE EXCEPTION 'FAIL [4d] fruehester: nicht gezaehlt, earliest, -100/Tag, 30 Tage, got %', r; END IF;
  SELECT * INTO r FROM finance.fn_account_everyday_basis(v_a) b ORDER BY b.period_end DESC LIMIT 1;
  IF NOT r.counted OR r.reason IS NOT NULL OR r.per_day IS DISTINCT FROM -10.00::numeric THEN
    RAISE EXCEPTION 'FAIL [4e] juengster gezaehlt, got %', r; END IF;
  -- die View traegt das Flag mit (abhaengige View ueberlebt den Signatur-Wechsel)
  IF (SELECT provisional FROM finance.account_everyday_spending WHERE account_id = v_a) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [4f] View account_everyday_spending.provisional'; END IF;
  RAISE NOTICE 'PASS fn_account_everyday_per_day: fruehester Auszug zaehlt nicht, Fenster 3, Details je Auszug';
END $$;

-- Einmalige Grossausgaben (Owner-Entscheid 2026-10-30): oneoff_out (Summe der ungematchten Abgaenge ab der Grenze,
-- Stempel oneoff_threshold) zaehlt nicht in per_day (Kontovorschau); per_day_net (Spar-Deckung) bleibt vorsichtig.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; r record;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ed_c__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  -- 30 Tage: -1000 raus, davon -700 einmalig (Grenze 250), +60 rein -> per_day -10, netto (-1000+60)/30 = -31.33
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at,
                                       oneoff_out, oneoff_threshold)
  VALUES (v_a, t - 34, t - 5, 2000, 1060, 'EUR', 5, 0, -1000, 60, NULL, -700, 250);
  SELECT * INTO r FROM finance.fn_account_everyday_per_day(v_a);
  IF r.per_day IS DISTINCT FROM -10.00::numeric OR r.per_day_net IS DISTINCT FROM -31.33::numeric THEN
    RAISE EXCEPTION 'FAIL [5a] per_day ohne Einmaliges -10, netto -31.33, got %', r; END IF;
  SELECT * INTO r FROM finance.fn_account_everyday_basis(v_a);
  IF r.per_day IS DISTINCT FROM -10.00::numeric OR r.oneoff_out IS DISTINCT FROM -700.00::numeric
     OR r.oneoff_threshold IS DISTINCT FROM 250.00::numeric THEN
    RAISE EXCEPTION 'FAIL [5b] basis: per_day -10, oneoff_out -700, Grenze 250, got %', r; END IF;

  -- Backstops: Einmaliges nie mehr als der ungematchte Abgang; ohne Grenze (alter Auszug) kein Einmaliges
  BEGIN
    UPDATE finance.bank_statements SET oneoff_out = -1000.01 WHERE account_id = v_a;
    RAISE EXCEPTION 'FAIL [5c] oneoff_out < unmatched_out angenommen';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    UPDATE finance.bank_statements SET oneoff_threshold = NULL WHERE account_id = v_a;
    RAISE EXCEPTION 'FAIL [5d] oneoff_out ohne Grenze angenommen';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    UPDATE finance.bank_statements SET oneoff_out = 5 WHERE account_id = v_a;
    RAISE EXCEPTION 'FAIL [5e] positives oneoff_out angenommen';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS fn_account_everyday_per_day: einmalige Grossausgaben zaehlen nicht in per_day, Backstops';
END $$;
ROLLBACK;
