-- ============================================================
-- V013 (core) — die alte 1-Arg-Signatur core.fn_fetch_context(text) droppen.
--
--   WARUM eine V-Migration: CREATE OR REPLACE kann die ARITAET einer Function NICHT aendern. P0b
--   gibt fn_fetch_context einen zweiten Parameter (p_chat_id, fuer die per_user-Aufloesung) — die
--   R__fn_fetch_context.sql legt jetzt core.fn_fetch_context(text, text DEFAULT NULL) an. Bliebe die
--   alte core.fn_fetch_context(text) stehen, koexistierten zwei Overloads und ein 1-Arg-Aufruf
--   (`fn_fetch_context('x')`) waere MEHRDEUTIG ("function is not unique") — der DEFAULT der neuen
--   2-Arg-Form matcht denselben Aufruf. Diese V droppt die 1-Arg-Form EINMALIG.
--
--   SICHER: kein DB-Objekt (Trigger/View/fn/Default) haengt an core.fn_fetch_context -> kein CASCADE
--   noetig. Aufrufer sind nur Workflow-SQL (load_context-Bindings; career_advisor uebergibt den 2.
--   Arg, die anderen rufen 1-Arg = neue Form mit Default) + Tests + util-Grant (auf die 2-Arg-Form
--   umgestellt). Der GRANT/REVOKE laeuft auf der NEUEN Signatur (R__/util in Phase 3/4). IDEMPOTENT
--   (IF EXISTS); Fresh DB = no-op (die R__ legt direkt die 2-Arg-Form an, die 1-Arg entstand nie).
--
-- APPLY-ORDER: Inits -> V (hier, droppt 1-Arg) -> R (legt 2-Arg an) -> util (grantet 2-Arg). Re-run-sicher.
-- ============================================================

DROP FUNCTION IF EXISTS core.fn_fetch_context(text);
