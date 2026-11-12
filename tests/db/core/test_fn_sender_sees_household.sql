-- tests/db/core/test_fn_sender_sees_household.sql
-- core.fn_sender_sees_household(p_chat_id text) — die eine Regel "sieht der Absender den Haushalt?" fuer den Chat
-- (Tor im Vermittler, Monitor, Hilfe-Agent, fn_fetch_context, Trigger-fns); Rollenteil = core.fn_app_sees_household.
--   1) owner/partner -> true; child, unbekannte uid, NULL, '' -> false
--   2) Test-Sentinel nur 'test_...' -> true; jede andere Form (Gruppe negativ, ueberlang, Leerzeichen, Buchstaben) -> false
--   3) DEFINER, gepinnter search_path, kein EXECUTE fuer PUBLIC und die engen Paket-Rollen, EXECUTE fuer core_ro
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v text;
BEGIN
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

  IF core.fn_sender_sees_household('880099001') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1a] partner'; END IF;
  IF core.fn_sender_sees_household('880099000') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1b] owner'; END IF;
  IF core.fn_sender_sees_household('880099002') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1c] child'; END IF;
  IF core.fn_sender_sees_household('880099999') IS NOT FALSE OR core.fn_sender_sees_household(NULL) IS NOT FALSE
     OR core.fn_sender_sees_household('') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1d] unbekannt/NULL/leer muessen false liefern (nie NULL)'; END IF;

  FOREACH v IN ARRAY ARRAY['-1001234567', '1234567890123456789012', ' 880099001', '880099001 ', 'abc', 'x_test_1', 'TEST_1'] LOOP
    IF core.fn_sender_sees_household(v) IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2a] % muss sperren', quote_literal(v); END IF;
  END LOOP;
  IF core.fn_sender_sees_household('test_ac01') IS NOT TRUE OR core.fn_sender_sees_household('test_e2e_x') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [2b] Test-Sentinel test_... muss durchgehen'; END IF;

  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'core.fn_sender_sees_household(text)'::regprocedure) THEN
    RAISE EXCEPTION 'FAIL [3a] SECURITY DEFINER'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'core.fn_sender_sees_household(text)'::regprocedure
                    AND 'search_path=pg_catalog, pg_temp' = ANY (proconfig)) THEN
    RAISE EXCEPTION 'FAIL [3b] search_path'; END IF;
  IF has_function_privilege('public', 'core.fn_sender_sees_household(text)', 'EXECUTE')
     OR has_function_privilege('finance_ro', 'core.fn_sender_sees_household(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [3c] kein EXECUTE fuer PUBLIC/finance_ro'; END IF;
  IF NOT has_function_privilege('core_ro', 'core.fn_sender_sees_household(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [3d] core_ro braucht EXECUTE (Hilfe-Agent, Monitor-Gate)'; END IF;
  IF to_regprocedure('finance.fn_sender_sees_household(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3e] die alte finance-Kopie muss weg sein (eine Adresse)'; END IF;
  RAISE NOTICE 'PASS test_fn_sender_sees_household';
END $$;
ROLLBACK;
