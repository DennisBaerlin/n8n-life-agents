-- tests/db/finance/test_fn_config_eur_in_currency.sql
-- finance.fn_config_eur_in_currency(key, default, currency, as_of) — EUR-Betrag aus core.config (Kategorie finance) in
--   eine Kontowaehrung: kaputter/negativer/fehlender Wert -> Default, 0 bleibt 0, EUR unveraendert, sonst Wert / Kurs
--   (ungerundeter Kurs, Ergebnis auf Cent), ohne Kurs NULL. Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v NUMERIC;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2), ('CHF', 2), ('KRW', 0) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency IN ('USD', 'CHF', 'KRW');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES
    ('EUR', 'USD', 1.25, t - 10), ('EUR', 'USD', 2, t - 1), ('EUR', 'KRW', 1450, t - 1);
  DELETE FROM core.config WHERE category = 'finance' AND key = '__t_cfg_eur__';

  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'EUR', t);
  IF v IS DISTINCT FROM 250 THEN RAISE EXCEPTION 'FAIL [1] fehlender Wert -> Default 250, got %', v; END IF;

  INSERT INTO core.config (package, category, key, value) VALUES ('finance', 'finance', '__t_cfg_eur__', '400');
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'EUR', t);
  IF v IS DISTINCT FROM 400 THEN RAISE EXCEPTION 'FAIL [2] EUR unveraendert 400, got %', v; END IF;
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'USD', t - 5);
  IF v IS DISTINCT FROM 500.00 THEN RAISE EXCEPTION 'FAIL [3] USD zum Stichtag (1.25) -> 500, got %', v; END IF;
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'USD', t);
  IF v IS DISTINCT FROM 800.00 THEN RAISE EXCEPTION 'FAIL [4] USD juengster Kurs (2) -> 800, got %', v; END IF;
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'KRW', t);
  IF v IS DISTINCT FROM 580000.00 THEN RAISE EXCEPTION 'FAIL [5] KRW ungerundeter Kurs -> 580000, got %', v; END IF;
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'CHF', t);
  IF v IS NOT NULL THEN RAISE EXCEPTION 'FAIL [6] ohne Kurs NULL (nie der rohe EUR-Wert), got %', v; END IF;

  UPDATE core.config SET value = '250€' WHERE category = 'finance' AND key = '__t_cfg_eur__';
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'EUR', t);
  IF v IS DISTINCT FROM 250 THEN RAISE EXCEPTION 'FAIL [7] kaputter Wert -> Default statt RAISE, got %', v; END IF;
  UPDATE core.config SET value = '-5' WHERE category = 'finance' AND key = '__t_cfg_eur__';
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'EUR', t);
  IF v IS DISTINCT FROM 250 THEN RAISE EXCEPTION 'FAIL [8] negativ -> Default, got %', v; END IF;
  UPDATE core.config SET value = '0' WHERE category = 'finance' AND key = '__t_cfg_eur__';
  v := finance.fn_config_eur_in_currency('__t_cfg_eur__', 250, 'EUR', t);
  IF v IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [9] 0 ist ein gueltiger Wert (Puffer 0), got %', v; END IF;
  RAISE NOTICE 'PASS fn_config_eur_in_currency: Default, EUR, Kurs zum Stichtag, ohne Kurs NULL, kaputter Wert';
END $$;
ROLLBACK;
