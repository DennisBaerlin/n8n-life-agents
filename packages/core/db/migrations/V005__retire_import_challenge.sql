-- ============================================================
-- V005 (core) — Phase 4b: die Typed-Challenge des CHAT-/import-Wipe-Gates ENTFERNEN.
--   Backup/Restore ist ab Phase 4b CLI-only (lifeagents backup); der Orchestrator-Pre-Router ruft
--   die Import-Challenge nicht mehr (Chat-Pfad retired, WP5). Damit sind die Tabelle + die zwei fns
--   tote Oberflaeche -> droppen (die R__-Dateien + der Init sind geloescht; CREATE OR REPLACE laeuft
--   nicht mehr -> dieser versioned DROP ist der Flyway-Standard fuer Entfernung, ledger-gegated).
--   PAIRING-Challenge (agent.pairing_state + fn_arm/consume_pairing_challenge) bleibt UNBERUEHRT —
--   andere Tabelle, andere fns, weiter genutzt (Multi-User-Pairing).
--   Fresh-DB: nie angelegt -> jeder DROP No-op.
-- ============================================================

DROP FUNCTION IF EXISTS agent.fn_arm_import_challenge(jsonb);
DROP FUNCTION IF EXISTS agent.fn_consume_import_challenge(jsonb);
DROP TABLE IF EXISTS agent.orchestrator_import_state;
