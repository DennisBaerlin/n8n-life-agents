-- tests/db/core/test_fn_app_sees_household.sql
-- core.fn_app_sees_household(p_person_id text) — die EINE Rollenfrage der Mini-App-Bildschirme (docs/package-contract.md
-- §3.12): Allow-List, nur owner/partner sehen den Haushalt; jede andere, unbekannte oder fehlende Rolle -> false.
--   1) owner/partner -> true; child, grandparent, unbekannte Person, NULL, '' -> false (Allow-List, nicht Deny-List)
--   2) DEFINER-Fenster: kein EXECUTE fuer PUBLIC und die engen Rollen (die Handler laufen als Eigentuemer)
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('asee_owner',   'Owner Beispiel',   'owner'),
    ('asee_partner', 'Partner Beispiel', 'partner'),
    ('asee_kid',     'Kind Beispiel',    'child'),
    ('asee_guest',   'Gast Beispiel',    'grandparent');

  IF core.fn_app_sees_household('asee_owner') IS NOT TRUE OR core.fn_app_sees_household('asee_partner') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1a] owner/partner muessen den Haushalt sehen'; END IF;
  IF core.fn_app_sees_household('asee_kid') IS NOT FALSE OR core.fn_app_sees_household('asee_guest') IS NOT FALSE
     OR core.fn_app_sees_household('asee_nobody') IS NOT FALSE OR core.fn_app_sees_household(NULL) IS NOT FALSE
     OR core.fn_app_sees_household('') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1b] jede andere/unbekannte/fehlende Rolle muss false liefern (nie NULL)'; END IF;
  RAISE NOTICE 'PASS [1] Allow-List owner/partner, sonst false';

  IF has_function_privilege('public', 'core.fn_app_sees_household(text)', 'EXECUTE')
     OR has_function_privilege('finance_ro', 'core.fn_app_sees_household(text)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'core.fn_app_sees_household(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [2] PUBLIC/finance_ro/core_ro duerfen den Helfer nicht ausfuehren'; END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'core.fn_app_sees_household(text)'::regprocedure) THEN
    RAISE EXCEPTION 'FAIL [2b] Helfer muss SECURITY DEFINER sein (liest agent.persons)'; END IF;
  RAISE NOTICE 'PASS [2] DEFINER, kein EXECUTE fuer PUBLIC/enge Rollen';
END $$;
ROLLBACK;
