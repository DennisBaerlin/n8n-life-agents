-- tests/db/core/test_advisor_plan_validate_fn.sql
-- core.advisors.plan_validate_fn: der Berater-Eintrag nennt die Plan-Pruefung seiner Domaene; die eine Pruefstelle
-- agent.fn_validate_context_facts fragt dort nach, wenn fuer ein Plan-Dokument keine context_validators-Zeile existiert.
--   (1) Spalte da, CHECK wie review_fn (nur schema.fn, lowercase, kein Injection-Zeichen)
--   (2) dritter Anlauf: Berater-Eintrag wird gerufen, exakter Name und per_user-Basisname
--   (3) Vorrang: eine context_validators-Zeile gilt zuerst
--   (4) fehlende fn (Paket weg) -> keine Pruefung, kein Fehler
-- Testfunktionen leben im Schema agent und fallen mit dem ROLLBACK weg. Alle Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_err TEXT;
BEGIN
  -- (1) Spalte + CHECK
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'core' AND table_name = 'advisors' AND column_name = 'plan_validate_fn') THEN
    RAISE EXCEPTION 'FAIL [Spalte]: core.advisors.plan_validate_fn fehlt';
  END IF;
  BEGIN
    EXECUTE $q$INSERT INTO core.advisors (domain, plan_context, review_fn, plan_validate_fn)
                VALUES ('chk1', 'x', 'finance.fn_x', 'fn_no_schema')$q$;
    RAISE EXCEPTION 'FAIL [check]: unqualifizierte plan_validate_fn akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: unqualifizierte plan_validate_fn abgewiesen]';
  END;
  BEGIN
    EXECUTE $q$INSERT INTO core.advisors (domain, plan_context, review_fn, plan_validate_fn)
                VALUES ('chk2', 'x', 'finance.fn_x', 'agent.fn_x; DROP TABLE core.config')$q$;
    RAISE EXCEPTION 'FAIL [check]: Injection-Zeichen akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: Injection-Zeichen in plan_validate_fn abgewiesen]';
  END;

  -- (2) dritter Anlauf
  CREATE FUNCTION agent.zz_test_plan_check(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
    SELECT CASE WHEN (p->'goal'->>'n')::numeric < 0 THEN 'goal.n must be >= 0' END
  $f$;
  EXECUTE $q$INSERT INTO core.advisors (domain, plan_context, review_fn, package, plan_validate_fn)
              VALUES ('zzpv', 'zzpv_planning', 'agent.zz_test_plan_check', 'core', 'agent.zz_test_plan_check')$q$;
  v_err := agent.fn_validate_context_facts(jsonb_build_object('goal', jsonb_build_object('n', -1)), 'zzpv_planning');
  IF v_err IS DISTINCT FROM 'goal.n must be >= 0' THEN
    RAISE EXCEPTION 'FAIL [Anlauf 3]: erwartet den Text der Plan-Pruefung, got %', v_err; END IF;
  v_err := agent.fn_validate_context_facts(jsonb_build_object('goal', jsonb_build_object('n', 1)), 'zzpv_planning');
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Anlauf 3 gueltig]: got %', v_err; END IF;
  RAISE NOTICE 'PASS [Berater-Eintrag liefert die Plan-Pruefung fuer den Plan-Kontext]';

  -- per_user: physischer Name '<base>__<pid>' findet den Eintrag ueber den Basisnamen
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('zzpv_planning', 'per_user', 'own_user_only', 'core')
  ON CONFLICT (context_name) DO UPDATE SET scope = 'per_user', write_permission = 'own_user_only';
  v_err := agent.fn_validate_context_facts(jsonb_build_object('goal', jsonb_build_object('n', -1)), 'zzpv_planning__erika');
  IF v_err IS DISTINCT FROM 'goal.n must be >= 0' THEN
    RAISE EXCEPTION 'FAIL [per_user Basisname]: got %', v_err; END IF;
  RAISE NOTICE 'PASS [per_user-Zeile findet die Plan-Pruefung ueber den Basisnamen]';

  -- ein fremder Kontext ohne Berater-Eintrag bleibt ungeprueft
  v_err := agent.fn_validate_context_facts(jsonb_build_object('goal', jsonb_build_object('n', -1)), 'zzother_planning');
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [fremder Kontext]: got %', v_err; END IF;

  -- (3) Vorrang der context_validators-Zeile
  CREATE FUNCTION agent.zz_test_registry_check(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $f$ SELECT 'registry wins'::text $f$;
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('zzpv_planning', 'agent.zz_test_registry_check', 'core');
  v_err := agent.fn_validate_context_facts(jsonb_build_object('goal', jsonb_build_object('n', 1)), 'zzpv_planning');
  IF v_err IS DISTINCT FROM 'registry wins' THEN
    RAISE EXCEPTION 'FAIL [Vorrang]: context_validators muss zuerst gelten, got %', v_err; END IF;
  DELETE FROM core.context_validators WHERE context_name = 'zzpv_planning';
  RAISE NOTICE 'PASS [context_validators-Zeile hat Vorrang]';

  -- (4) fn nicht mehr vorhanden (Paket deinstalliert, Zeile noch da) -> keine Pruefung, kein Fehler
  DROP FUNCTION agent.zz_test_plan_check(jsonb);
  v_err := agent.fn_validate_context_facts(jsonb_build_object('goal', jsonb_build_object('n', -1)), 'zzpv_planning');
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [fn fehlt]: erwartet NULL, got %', v_err; END IF;
  RAISE NOTICE 'PASS [fehlende Plan-Pruefung entfaellt still]';
END $$;

ROLLBACK;
