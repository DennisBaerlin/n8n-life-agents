-- tests/db/core/test_core_advisors.sql
-- WS2 (Core-Advisor-Engine): die Registry-Host-Tabelle core.advisors. Sichert die strukturellen
-- Invarianten (DB ist Gesetz), unabhaengig vom Dispatch-/Latch-Verhalten (das deckt
-- test_fn_advisor_review_evaluate ab):
--   (1) gueltige schema-qualifizierte review_fn-Bindung akzeptiert,
--   (2) CHECK weist nicht-qualifizierte / Injection-/Mixed-Case-Bezeichner ab,
--   (3) PRIMARY KEY domain -> eine Zeile je Advisor-Domain.
-- (Phase Notify: der frueher hier mitgetestete Latch-State core.advisor_review_state ist auf die
--  GETEILTE core.notification_state migriert; deren PK/CHECK testet test_fn_should_notify.sql.)
BEGIN;

DO $$
BEGIN
  -- ---------- TEST 1: gueltige Bindung akzeptiert ----------
  INSERT INTO core.advisors (domain, plan_context, review_fn, package)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'finance');
  RAISE NOTICE 'PASS [gueltige Advisor-Registry-Zeile akzeptiert]';

  -- ---------- TEST 2: PRIMARY KEY -> eine Zeile je Domain ----------
  BEGIN
    INSERT INTO core.advisors (domain, plan_context, review_fn)
    VALUES ('finance', 'other_plan', 'other.fn_x');
    RAISE EXCEPTION 'FAIL [pk]: doppelte domain akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [PRIMARY KEY: eine Zeile je Advisor-Domain]';
  END;

  -- ---------- TEST 3a: CHECK weist unqualifizierte review_fn ab ----------
  BEGIN
    INSERT INTO core.advisors (domain, plan_context, review_fn)
    VALUES ('foo', 'x', 'fn_no_schema');
    RAISE EXCEPTION 'FAIL [check no-schema]: unqualifizierte review_fn akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: unqualifizierte review_fn abgewiesen]';
  END;

  -- ---------- TEST 3c/3d: dieselbe CHECK-Regel fuer die Plan-Schritt-Felder gaps_fn / readiness_fn (2026-10-28) ----------
  BEGIN
    INSERT INTO core.advisors (domain, plan_context, review_fn, plan_step, gaps_fn)
    VALUES ('gapsx', 'x', 'finance.fn_x', true, 'fn_no_schema');
    RAISE EXCEPTION 'FAIL [check gaps_fn no-schema]: unqualifizierte gaps_fn akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: unqualifizierte gaps_fn abgewiesen]';
  END;
  BEGIN
    INSERT INTO core.advisors (domain, plan_context, review_fn, plan_step, readiness_fn)
    VALUES ('readyx', 'x', 'finance.fn_x', true, 'Finance.Fn_Plan_Readiness');
    RAISE EXCEPTION 'FAIL [check readiness_fn case]: gemischte Schreibweise akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: readiness_fn in gemischter Schreibweise abgewiesen]';
  END;

  -- ---------- TEST 3b: CHECK weist Injection-/Sonderzeichen ab ----------
  BEGIN
    INSERT INTO core.advisors (domain, plan_context, review_fn)
    VALUES ('bar', 'x', 'finance.fn_x; DROP TABLE core.config');
    RAISE EXCEPTION 'FAIL [check injection]: Sonderzeichen akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: Injection-/Sonderzeichen abgewiesen]';
  END;

  -- ---------- TEST 3c: CHECK weist Mixed-Case ab ----------
  BEGIN
    INSERT INTO core.advisors (domain, plan_context, review_fn)
    VALUES ('baz', 'x', 'Finance.Fn_Mixed');
    RAISE EXCEPTION 'FAIL [check uppercase]: Mixed-Case akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: Mixed-Case abgewiesen]';
  END;

END $$;

ROLLBACK;
