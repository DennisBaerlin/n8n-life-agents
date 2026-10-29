-- tests/db/finance/test_fn_account_flows.sql
-- finance.fn_account_flows(acct) — laufende und kommende Dauerauftraege eines Kontos: side in/out, Monatsbetrag signiert in
-- Kontowaehrung (Uebertrags-Ziel ueber den Kurs, ohne Kurs NULL), je Kette das massgebliche Glied, beendete nie.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_usd INT; v_chf INT; r_c1 INT; v_got text;
BEGIN
  PERFORM finance.fn_ensure_currency('USD');
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'USD', 1.10, t - 1)
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_af_a__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_af_usd__', 'cash', 'USD', 'active') RETURNING id INTO v_usd;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_af_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;

  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to) VALUES
    ('af eingang', v_a,   NULL,   50, 'month', t + 1, t + 1, NULL),
    ('af abgang',  v_a,   NULL, -200, 'month', t + 2, t + 2, NULL),
    ('af a->usd',  v_a,   v_usd, -100, 'month', t + 3, t + 3, NULL),
    ('af a->chf',  v_a,   v_chf, -100, 'month', t + 3, t + 3, NULL),
    ('af beendet', v_a,   NULL,  -10, 'month', t - 90, t - 90, t - 5);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('af kette alt', v_a, -30, 'month', t - 60, t - 60, t + 60) RETURNING id INTO r_c1;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('af kette neu', v_a, -40, 'month', t - 60, t + 60, r_c1);

  SELECT string_agg(r.name || ':' || f.side || ':' || round(f.monthly, 2), ',' ORDER BY r.name) INTO v_got
    FROM finance.fn_account_flows(v_a) f JOIN finance.recurring_payments r ON r.id = f.rp_id;
  IF v_got IS DISTINCT FROM 'af a->chf:out:-100.00,af a->usd:out:-100.00,af abgang:out:-200.00,af eingang:in:50.00,af kette alt:out:-30.00' THEN
    RAISE EXCEPTION 'FAIL [1] Quell-Konto, got %', v_got; END IF;
  SELECT string_agg(f.side || ':' || round(f.monthly, 2), ',') INTO v_got FROM finance.fn_account_flows(v_usd) f;
  IF v_got IS DISTINCT FROM 'in:110.00' THEN RAISE EXCEPTION 'FAIL [2] Ziel in USD 110, got %', v_got; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_account_flows(v_chf) f WHERE f.side = 'in' AND f.monthly IS NULL) THEN
    RAISE EXCEPTION 'FAIL [3] Ziel ohne Kurs -> NULL'; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_account_flows(-1)) THEN RAISE EXCEPTION 'FAIL [4] unbekannt -> leer'; END IF;
  RAISE NOTICE 'PASS fn_account_flows: in/out, Zielwaehrung, ohne Kurs NULL, ein Glied je Kette, beendet nie';
END $$;
ROLLBACK;
