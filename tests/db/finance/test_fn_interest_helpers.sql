-- tests/db/finance/test_fn_interest_helpers.sql
-- DRY-Helfer fuer die vorgeschlagenen Zins-Defaults: day-count-Methode aus dem Kontotyp, auto_post aus der Kadenz.
BEGIN;

DO $$
BEGIN
  -- fn_interest_default_convention: cash->ACT/365, fixed_deposit->30E/360, sonst ACT/365
  IF finance.fn_interest_default_convention('cash')          IS DISTINCT FROM 'ACT/365' THEN RAISE EXCEPTION 'FAIL [conv cash]'; END IF;
  IF finance.fn_interest_default_convention('fixed_deposit') IS DISTINCT FROM '30E/360' THEN RAISE EXCEPTION 'FAIL [conv fixed_deposit]'; END IF;
  IF finance.fn_interest_default_convention('p2p')           IS DISTINCT FROM 'ACT/365' THEN RAISE EXCEPTION 'FAIL [conv fallback]'; END IF;
  RAISE NOTICE 'PASS [default_convention: cash=ACT/365, fixed_deposit=30E/360, sonst ACT/365]';

  -- fn_interest_auto_post_default: day/week->true, month/year->false
  IF finance.fn_interest_auto_post_default('day')   IS DISTINCT FROM true  THEN RAISE EXCEPTION 'FAIL [auto day]'; END IF;
  IF finance.fn_interest_auto_post_default('week')  IS DISTINCT FROM true  THEN RAISE EXCEPTION 'FAIL [auto week]'; END IF;
  IF finance.fn_interest_auto_post_default('month') IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [auto month]'; END IF;
  IF finance.fn_interest_auto_post_default('year')  IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [auto year]'; END IF;
  RAISE NOTICE 'PASS [auto_post_default: day/week=true, month/year=false]';
END $$;

ROLLBACK;
