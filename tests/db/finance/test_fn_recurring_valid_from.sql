-- tests/db/finance/test_fn_recurring_valid_from.sql
-- Testet fn_recurring_valid_from: Konto mit Eroeffnungssaldo -> fruehestens dessen Stichtag; ohne -> unveraendert.
BEGIN;

DO $$
DECLARE
  v_open  INT;
  v_plain INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_rvf_open__","account_type":"cash","opening_balance":0}'::jsonb)->>'account_id')::int INTO v_open;
  SELECT (finance.fn_create_account('{"name":"__test_rvf_plain__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_plain;

  IF finance.fn_recurring_valid_from(v_open, DATE '2020-01-01') IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL rvf [Stichtag]: Vergangenes Datum auf Konto mit Saldo (auch 0) -> heute erwartet, got %',
      finance.fn_recurring_valid_from(v_open, DATE '2020-01-01');
  END IF;
  IF finance.fn_recurring_valid_from(v_open, CURRENT_DATE + 10) IS DISTINCT FROM CURRENT_DATE + 10 THEN
    RAISE EXCEPTION 'FAIL rvf [Zukunft]: kuenftiges Datum bleibt';
  END IF;
  IF finance.fn_recurring_valid_from(v_plain, DATE '2020-01-01') IS DISTINCT FROM DATE '2020-01-01' THEN
    RAISE EXCEPTION 'FAIL rvf [ohne Saldo]: Datum bleibt unveraendert (offene Faelligkeiten sichtbar)';
  END IF;
  IF finance.fn_recurring_valid_from(NULL, DATE '2020-01-01') IS DISTINCT FROM DATE '2020-01-01' THEN
    RAISE EXCEPTION 'FAIL rvf [kein Konto]: Datum bleibt unveraendert';
  END IF;
  RAISE NOTICE 'PASS fn_recurring_valid_from [Stichtag / Zukunft / ohne Saldo / ohne Konto]';

  -- Vergangener Stichtag (Endsaldo eines Kontoauszugs = Tagesende): auch der Stichtag selbst steckt im Saldo
  DECLARE v_stmt INT; v_d DATE := core.fn_today() - 5; BEGIN
    SELECT (finance.fn_create_account(jsonb_build_object('name', '__test_rvf_stmt__', 'account_type', 'cash',
              'opening_balance', '150', 'opening_balance_date', to_char(v_d, 'YYYY-MM-DD')))->>'account_id')::int INTO v_stmt;
    IF finance.fn_recurring_valid_from(v_stmt, DATE '2020-01-01') IS DISTINCT FROM v_d + 1 THEN
      RAISE EXCEPTION 'FAIL rvf [vergangener Stichtag]: Folgetag % erwartet, got %', v_d + 1,
        finance.fn_recurring_valid_from(v_stmt, DATE '2020-01-01');
    END IF;
  END;
  RAISE NOTICE 'PASS fn_recurring_valid_from [vergangener Stichtag -> Folgetag]';
END $$;

ROLLBACK;
