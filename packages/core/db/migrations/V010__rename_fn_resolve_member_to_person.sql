-- ============================================================
-- V010 (core) — Rename agent.fn_resolve_member -> core.fn_resolve_person (WS-4).
--
--   WARUM eine V-Migration: ein fn-NAME-/SCHEMA-Rename ist KEIN CREATE OR REPLACE — die neue
--   Funktion (core.fn_resolve_person, R__fn_resolve_person.sql) entsteht unter neuem Namen, die
--   ALTE agent.fn_resolve_member bliebe sonst verwaist liegen. Dieser einmalige DROP raeumt sie weg
--   (db/CLAUDE.md *Migrations-Modell*; enforcement-Gotcha „fn-Rename braucht V-DROP").
--
--   Der Resolver zog von agent nach core, weil die engen Paket-Rollen (finance_rw/finance_ro)
--   USAGE nur auf pg_catalog,<pkg>,core haben (KEIN agent, D10) — agent.fn_resolve_member war fuer
--   sie nie aufrufbar (= war eine echte Waise). core.fn_resolve_person ist das publizierte Fenster.
--
--   SICHER + IDEMPOTENT: IF EXISTS-geguardet; ein erneuter Lauf ist no-op. Kein Caller betroffen
--   (agent.fn_resolve_member hatte repo-weit keinen Laufzeit-Aufrufer).
-- ============================================================

DROP FUNCTION IF EXISTS agent.fn_resolve_member(text);
