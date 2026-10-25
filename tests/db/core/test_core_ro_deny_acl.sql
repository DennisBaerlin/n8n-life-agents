-- tests/db/core/test_core_ro_deny_acl.sql
-- Security-Audit 2026-10 (Owner "strikt privat"): die Deny-Liste in util_create_core_ro.sql haelt den Frei-SQL-Pfad
-- (core_ro: guide/monitor-LLM, Monitor-Specs) von fremden Gespraechen, Einmal-Codes, rohen Eingaengen und offenen
-- Auftragstexten fern; context_ro liest agent.core_contexts nicht mehr direkt (nur ueber core.fn_fetch_context).
-- Faengt die Drift-Klasse "ein Rollen-Re-Apply re-grantet still" (Muster test_core_backup_key_acl.sql).
BEGIN;

DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') INTO v_bad
    FROM pg_tables
   WHERE schemaname = 'agent'
     AND (right(tablename, 12) = '_chat_memory' OR tablename IN ('pairing_state', 'ingress_buffer', 'hitl_pending'))
     AND has_table_privilege('core_ro', format('%I.%I', schemaname, tablename), 'SELECT');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL acl [core_ro kann % lesen — Deny-Liste in util_create_core_ro.sql pruefen]', v_bad;
  END IF;
  IF to_regclass('agent.pairing_state') IS NULL OR to_regclass('agent.ingress_buffer') IS NULL
     OR to_regclass('agent.hitl_pending') IS NULL THEN
    RAISE EXCEPTION 'FAIL acl [Deny-Listen-Tabelle fehlt — Test prueft ins Leere]';
  END IF;
  -- /kosten: die KI-Nutzung je Workflow (Tagesablauf des Owners) nur ueber core.fn_get_llm_cost_report (Owner-Gate)
  IF to_regclass('core.llm_usage') IS NULL OR has_table_privilege('core_ro', 'core.llm_usage', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL acl [core_ro liest core.llm_usage direkt (oder Tabelle fehlt) — Deny-Liste pruefen]';
  END IF;
  IF has_table_privilege('context_ro', 'agent.core_contexts', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL acl [context_ro liest agent.core_contexts direkt — util_create_context_ro.sql pruefen]';
  END IF;
  RAISE NOTICE 'PASS core_ro_deny_acl [Deny-Liste dicht, context_ro nur ueber das Fenster]';
END $$;

ROLLBACK;
