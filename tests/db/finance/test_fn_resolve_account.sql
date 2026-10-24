-- tests/db/finance/test_fn_resolve_account.sql
-- Testet fn_resolve_account: Name->ID, Ambiguitaet (0/1/>1 Treffer), active_only- + type-Filter.
BEGIN;

DO $$
DECLARE
  v_id INT; v_hits INT;
BEGIN
  INSERT INTO finance.accounts (name, account_type, status) VALUES
    ('__res_uniq__',   'cash', 'active'),
    ('__res_dup__',    'cash', 'active'),
    ('__res_dup__',    'cash', 'active'),
    ('__res_closed__', 'cash', 'closed'),
    ('__res_typed__',  'cash', 'active');

  -- genau 1 Treffer -> id gesetzt
  SELECT id, hit_count INTO v_id, v_hits FROM finance.fn_resolve_account('__res_uniq__');
  IF v_hits <> 1 OR v_id IS NULL THEN RAISE EXCEPTION 'FAIL resolve_account [1 hit]: hits=%, id=%', v_hits, v_id; END IF;

  -- >1 Treffer -> id NULL, hit_count=2
  SELECT id, hit_count INTO v_id, v_hits FROM finance.fn_resolve_account('__res_dup__');
  IF v_hits <> 2 OR v_id IS NOT NULL THEN RAISE EXCEPTION 'FAIL resolve_account [>1]: hits=%, id=%', v_hits, v_id; END IF;

  -- 0 Treffer
  SELECT id, hit_count INTO v_id, v_hits FROM finance.fn_resolve_account('__nonexistent__');
  IF v_hits <> 0 OR v_id IS NOT NULL THEN RAISE EXCEPTION 'FAIL resolve_account [0]: hits=%', v_hits; END IF;

  -- active_only filtert closed weg
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_account('__res_closed__', NULL, TRUE);
  IF v_hits <> 0 THEN RAISE EXCEPTION 'FAIL resolve_account [active_only]: closed sichtbar, hits=%', v_hits; END IF;
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_account('__res_closed__', NULL, FALSE);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'FAIL resolve_account [active_only=false]: hits=%', v_hits; END IF;

  -- type-Filter
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_account('__res_typed__', ARRAY['stocks_depot'], TRUE);
  IF v_hits <> 0 THEN RAISE EXCEPTION 'FAIL resolve_account [type mismatch]: hits=%', v_hits; END IF;
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_account('__res_typed__', ARRAY['cash'], TRUE);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'FAIL resolve_account [type match]: hits=%', v_hits; END IF;

  RAISE NOTICE 'PASS fn_resolve_account: 1/>1/0-Treffer + active_only + type-Filter';

  -- currency: Kontowaehrung des eindeutigen Treffers, NULL bei 0 oder mehreren Treffern
  DECLARE v_ccy TEXT; BEGIN
    INSERT INTO finance.currencies (code) VALUES ('USD') ON CONFLICT DO NOTHING;
    INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__res_usd__', 'cash', 'USD');
    SELECT currency INTO v_ccy FROM finance.fn_resolve_account('__res_usd__');
    IF v_ccy IS DISTINCT FROM 'USD' THEN RAISE EXCEPTION 'FAIL resolve_account [currency unique]: %', v_ccy; END IF;
    INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__res_usd__', 'cash', 'USD');
    SELECT currency INTO v_ccy FROM finance.fn_resolve_account('__res_usd__');
    IF v_ccy IS NOT NULL THEN RAISE EXCEPTION 'FAIL resolve_account [currency ambiguous -> NULL]: %', v_ccy; END IF;
  END;
  RAISE NOTICE 'PASS fn_resolve_account: currency bei eindeutigem Treffer, NULL bei Mehrdeutigkeit';
END $$;

ROLLBACK;
