-- tests/db/finance/test_fn_sender_sees_household.sql
-- finance.fn_sender_sees_household(p_chat_id text) — Tor vor beiden Finanz-Agenten: nur owner/partner sehen die
-- Haushaltsfinanzen im Chat (dieselbe Regel wie die Mini-App, core.fn_app_sees_household).
--   1) owner/partner -> true; child, Person ohne Rolle, unbekannte uid, NULL, '' -> false
--   2) nicht-numerische chat_id (Test-Sentinel der Agent-Tiers) -> true, ohne Cast-Fehler
--   3) DEFINER, gepinnter search_path, kein EXECUTE fuer PUBLIC und die engen Paket-Rollen
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
BEGIN
  -- family-Context mit gepairten Personen (Muster tests/db/cross/test_role_permissions.sql); trg_project_persons spiegelt
  -- sie nach agent.persons, das fn_app_sees_household liest.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'shh sender fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id', 'shh_owner', 'first_name', 'Olaf', 'last_name', 'Testfall', 'role', 'owner',
                               'birth_date', '1980-01-01', 'telegram_user_id', 880099000, 'as_of', '2026-06-11'),
            jsonb_build_object('person_id', 'shh_partner', 'first_name', 'Pia', 'last_name', 'Testfall', 'role', 'partner',
                               'birth_date', '1985-02-02', 'telegram_user_id', 880099001, 'as_of', '2026-06-11'),
            jsonb_build_object('person_id', 'shh_kid', 'first_name', 'Kim', 'last_name', 'Testfall', 'role', 'child',
                               'birth_date', '2014-03-03', 'telegram_user_id', 880099002, 'as_of', '2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

  IF finance.fn_sender_sees_household('880099001') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1a] partner muss den Haushalt sehen'; END IF;
  IF finance.fn_sender_sees_household('880099000') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1b] owner muss den Haushalt sehen'; END IF;
  IF finance.fn_sender_sees_household('880099002') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1c] child darf den Haushalt nicht sehen'; END IF;
  IF finance.fn_sender_sees_household('880099999') IS NOT FALSE
     OR finance.fn_sender_sees_household(NULL) IS NOT FALSE
     OR finance.fn_sender_sees_household('') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1d] unbekannte uid, NULL und leer muessen false liefern (nie NULL)'; END IF;
  IF finance.fn_sender_sees_household('-1001234567') IS NOT FALSE
     OR finance.fn_sender_sees_household('1234567890123456789012') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1e] Gruppen-chat_id (negativ) und ueberlange Zahl muessen sperren, nicht als Test durchgehen'; END IF;
  RAISE NOTICE 'PASS [1] owner/partner true, child/unbekannt/leer false';

  IF finance.fn_sender_sees_household('test_ac01') IS NOT TRUE OR finance.fn_sender_sees_household('test_e2e_x') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [2] nicht-numerische Test-chat_id muss durchgelassen werden'; END IF;
  RAISE NOTICE 'PASS [2] Test-Sentinel durchgelassen';

  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'finance.fn_sender_sees_household(text)'::regprocedure) THEN
    RAISE EXCEPTION 'FAIL [3a] muss SECURITY DEFINER sein'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'finance.fn_sender_sees_household(text)'::regprocedure
                    AND 'search_path=pg_catalog, pg_temp' = ANY (proconfig)) THEN
    RAISE EXCEPTION 'FAIL [3b] search_path muss auf pg_catalog, pg_temp gepinnt sein'; END IF;
  IF has_function_privilege('public', 'finance.fn_sender_sees_household(text)', 'EXECUTE')
     OR has_function_privilege('finance_ro', 'finance.fn_sender_sees_household(text)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'finance.fn_sender_sees_household(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [3c] kein EXECUTE fuer PUBLIC/finance_ro/core_ro'; END IF;
  RAISE NOTICE 'PASS [3] DEFINER, gepinnter search_path, kein EXECUTE fuer PUBLIC/enge Rollen';
END $$;
ROLLBACK;
