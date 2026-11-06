-- ============================================================
-- V029 (core) — core.cron_labels verliert die Text-Spalten (Textkatalog Phase B).
--
--   Die Toast-/Meldungstexte der Erinnerungs-Schalter stehen jetzt im Textkatalog (<pkg>.cron.<key>.on_toast|off_toast|
--   on_message|off_message, docs/package-contract.md §3.11) und kommen in der Sprache des Tippenden. Die Tabelle bleibt die
--   Schaltbarkeits-Registry (Mitgliedschaft cron_key + package; core.fn_set_cron_enable prueft genau sie).
--   Das Init (core.cron_labels_init.sql) traegt den Endzustand; dieser V-Schritt raeumt bestehende Instanzen.
--   Destruktiver DROP -> versioned (.claude/rules/sql.md). Re-run-sicher (IF EXISTS).
-- ============================================================

ALTER TABLE core.cron_labels DROP COLUMN IF EXISTS on_toast;
ALTER TABLE core.cron_labels DROP COLUMN IF EXISTS off_toast;
ALTER TABLE core.cron_labels DROP COLUMN IF EXISTS on_message;
ALTER TABLE core.cron_labels DROP COLUMN IF EXISTS off_message;
