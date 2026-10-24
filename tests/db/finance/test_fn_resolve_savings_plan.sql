-- tests/db/finance/test_fn_resolve_savings_plan.sql
-- Testet fn_resolve_savings_plan: 1 / 0 Treffer, ci-Treffer ohne Pattern-Semantik (Namen selbst sind
-- UNIQUE lower(name)) + p_active_only-Zweig (paused unsichtbar bei TRUE, sichtbar bei FALSE).
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_settle INT; v_id1 INT; v_id2 INT; v_id INT; v_count INT;
BEGIN
  -- Setup: Verrechnungskonto + Depot + zwei Sparplaene
  SELECT finance.fn_create_account('{"name":"__test_rsp_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb) INTO v_res;
  v_settle := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object(
    'name','__test_rsp_depot__','account_type','stocks_depot','account_holder','Test',
    'currency','EUR','settlement_id',v_settle)) INTO v_res;

  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name','__test_rsp_one__','depot_name','__test_rsp_depot__','isin','IE00B4L5Y983',
    'symbol','IWDA','security_name','MSCI World','amount',100,
    'first_payment_date','2026-07-01','schedule_day_of_month',1)) INTO v_res;
  v_id1 := (v_res->>'savings_plan_id')::int;
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name','__test_rsp_two__','depot_name','__test_rsp_depot__','isin','IE00B3RBWM25',
    'symbol','VWRL','security_name','FTSE All-World','amount',150,
    'first_payment_date','2026-07-01','schedule_day_of_month',1)) INTO v_res;
  v_id2 := (v_res->>'savings_plan_id')::int;

  -- TEST 1: eindeutiger Treffer
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_plan('__test_rsp_one__');
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'FAIL resolve_savings_plan [unique]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_savings_plan [unique]';

  -- TEST 2: kein Treffer
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_plan('__test_rsp_none__');
  IF v_count IS DISTINCT FROM 0 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_savings_plan [none]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_savings_plan [none]';

  -- TEST 3 (Vertragsaenderung DB-ist-das-Gesetz S3): erst exakt, sonst ohne Gross-/Kleinschreibung; KEIN Pattern mehr
  -- (ILIKE machte '_'/'%' im Namen zu Platzhaltern). Namen sind unique lower(name) -> ci-Treffer ist eindeutig.
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_plan(' __TEST_RSP_ONE__ ');
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'FAIL resolve_savings_plan [ci]: count=% id=%', v_count, v_id; END IF;
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_plan('__test_rsp_%');
  IF v_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL resolve_savings_plan [kein Pattern mehr]: count=%', v_count; END IF;
  RAISE NOTICE 'PASS resolve_savings_plan [ci, kein Pattern]';

  -- TEST 4: p_active_only -- paused unsichtbar bei TRUE (Default), sichtbar bei FALSE
  UPDATE finance.savings_plans SET status = 'paused' WHERE id = v_id2;
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_plan('__test_rsp_two__');
  IF v_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL resolve_savings_plan [active_only=TRUE]: paused gefunden, count=%', v_count; END IF;
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_plan('__test_rsp_two__', FALSE);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id2 THEN
    RAISE EXCEPTION 'FAIL resolve_savings_plan [active_only=FALSE]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_savings_plan [p_active_only beide Zweige]';
END $$;

ROLLBACK;
