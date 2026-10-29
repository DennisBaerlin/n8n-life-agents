-- tests/db/finance/test_fn_account_projection.sql
-- finance.fn_account_projection(acct, from, until, per_day) — der EINE Rechenkern der Kontovorschau (fn_account_outlook)
-- und der Spar-Deckung (fn_account_funding): Tagesreihe = Stand zum Vortag + Buchungen + offene Dauerauftrags-Vorkommen
-- (Quell-Seite signiert, Ziel-Seite eines Uebertrags in ZIELwaehrung) + Alltagsausgaben je Tag.
--   1) Reihe auch an Tagen ohne Fluss, Zu-/Abfluss am selben Tag getrennt, Uebertrag aufs Konto zaehlt, per_day je Tag.
--   2) Ziel-Seite in Fremdwaehrung ueber den Kurs; ohne Kurs -> Quellbetrag roh + fx_gap.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_b INT; v_usd INT; v_chf INT; r record; v_n INT;
BEGIN
  PERFORM finance.fn_ensure_currency('USD');
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'USD', 1.10, t - 1)
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_pj_a__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_pj_b__', 'cash', 'EUR', 'active') RETURNING id INTO v_b;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_pj_usd__', 'cash', 'USD', 'active') RETURNING id INTO v_usd;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_pj_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 1000, t - 40, 'other');
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('pj raus',   v_a, NULL,  -30, 30, 'day', t + 2, t + 2),
         ('pj rein',   v_a, NULL,   20, 30, 'day', t + 2, t + 2),
         ('pj b->a',   v_b, v_a,   -50, 30, 'day', t + 5, t + 5),
         ('pj a->usd', v_a, v_usd, -100, 30, 'day', t + 7, t + 7),
         ('pj a->chf', v_a, v_chf, -100, 30, 'day', t + 8, t + 8);

  -- 1) Konto A, 11 Tage: t 1000; t+2 +20/-30 = 990; t+5 +50 = 1040; t+7 -100 = 940; t+8 -100 = 840
  SELECT count(*) INTO v_n FROM finance.fn_account_projection(v_a, t, t + 10, 0);
  IF v_n <> 11 THEN RAISE EXCEPTION 'FAIL [1a] 11 Tage erwartet, got %', v_n; END IF;
  SELECT * INTO r FROM finance.fn_account_projection(v_a, t, t + 10, 0) p WHERE p.day = t + 2;
  IF r.bal IS DISTINCT FROM 990::numeric OR r.inflow IS DISTINCT FROM 20::numeric OR r.outflow IS DISTINCT FROM -30::numeric
     OR r.fx_gap THEN
    RAISE EXCEPTION 'FAIL [1b] t+2 Zu/Ab getrennt, got %', r; END IF;
  SELECT * INTO r FROM finance.fn_account_projection(v_a, t, t + 10, 0) p WHERE p.day = t + 10;
  IF r.bal IS DISTINCT FROM 840::numeric OR r.inflow <> 0 OR r.outflow <> 0 THEN
    RAISE EXCEPTION 'FAIL [1c] t+10 840 (Tag ohne Fluss), got %', r; END IF;
  SELECT * INTO r FROM finance.fn_account_projection(v_a, t, t + 1, -10) p WHERE p.day = t + 1;
  IF r.bal IS DISTINCT FROM 980::numeric THEN RAISE EXCEPTION 'FAIL [1d] per_day -10 je Tag, got %', r; END IF;
  RAISE NOTICE 'PASS [1] Tagesreihe, Zu-/Abfluss getrennt, Uebertrag aufs Konto, Alltag je Tag';

  -- 2) Ziel-Seite in Zielwaehrung: 100 EUR -> 110 USD; ohne CHF-Kurs zaehlt der Quellbetrag roh (nie still 0) + fx_gap
  SELECT * INTO r FROM finance.fn_account_projection(v_usd, t, t + 10, 0) p WHERE p.day = t + 7;
  IF r.inflow IS DISTINCT FROM 110.00::numeric OR r.bal IS DISTINCT FROM 110.00::numeric OR r.fx_gap THEN
    RAISE EXCEPTION 'FAIL [2a] USD-Ziel 110, got %', r; END IF;
  SELECT * INTO r FROM finance.fn_account_projection(v_chf, t, t + 10, 0) p WHERE p.day = t + 8;
  IF r.inflow IS DISTINCT FROM 100::numeric OR r.bal IS DISTINCT FROM 100::numeric OR NOT r.fx_gap THEN
    RAISE EXCEPTION 'FAIL [2b] CHF-Ziel ohne Kurs -> Rohbetrag 100 + fx_gap, got %', r; END IF;
  RAISE NOTICE 'PASS [2] Ziel-Seite in Zielwaehrung, ohne Kurs Rohbetrag + fx_gap';
END $$;
ROLLBACK;
