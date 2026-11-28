-- ============================================================
-- V042 (core) — tote Werte aus zwei Tabellen-Regeln entfernen
--   agent.reaction_log.kind 'mood': agent.fn_claim_reaction schreibt die Art nicht mehr (V038 entfernte ihre Obergrenze);
--     Alt-Zeilen sind fluechtiges Protokoll (30 Tage, nicht im Backup) und fallen weg, dann werden Arten- und Koppel-CHECK
--     ohne 'mood' neu gesetzt.
--   core.package_registry.status 'installed': kein Lebenszyklus-Schritt setzt ihn; eine Alt-Zeile hiesse "abgebrochen" wie
--     'installing' und wird dorthin gelegt, dann gilt der CHECK ohne 'installed'.
--   Das Init traegt den Endzustand (frische DB = no-op bis auf den Tausch gleicher Regeln). Re-run-sicher.
--   squawk ban-drop-constraint je Zeile ausgenommen: Drop und Neu-Anlage unter demselben Namen in derselben Transaktion,
--   die neue Regel ist enger (keine Garantie geht verloren).
--   Test: tests/db/cross/test_dead_schema_values.sql
-- ============================================================
DELETE FROM agent.reaction_log WHERE kind = 'mood';
-- squawk-ignore ban-drop-constraint
ALTER TABLE agent.reaction_log DROP CONSTRAINT IF EXISTS reaction_log_kind_valid;
ALTER TABLE agent.reaction_log ADD CONSTRAINT reaction_log_kind_valid CHECK (kind IN ('seen', 'done', 'answer'));
-- squawk-ignore ban-drop-constraint
ALTER TABLE agent.reaction_log DROP CONSTRAINT IF EXISTS reaction_log_kind_emoji;
ALTER TABLE agent.reaction_log ADD CONSTRAINT reaction_log_kind_emoji CHECK (
       (kind = 'seen' AND emoji = '👀')
    OR (kind = 'done' AND emoji = '👌')
    OR (kind = 'answer' AND emoji IN ('❤', '🎉', '🙏', '😁')));

UPDATE core.package_registry SET status = 'installing' WHERE status = 'installed';
-- squawk-ignore ban-drop-constraint
ALTER TABLE core.package_registry DROP CONSTRAINT IF EXISTS package_registry_status_check;
ALTER TABLE core.package_registry ADD CONSTRAINT package_registry_status_check
    CHECK (status IN ('installing', 'active', 'inactive'));
