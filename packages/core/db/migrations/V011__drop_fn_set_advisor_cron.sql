-- ============================================================
-- V011 (core) — Rename core.fn_set_advisor_cron -> core.fn_set_cron_enable (Phase D).
--
--   WARUM eine V-Migration: ein fn-NAME-Rename ist KEIN CREATE OR REPLACE — die neue Funktion
--   (core.fn_set_cron_enable, R__fn_set_cron_enable.sql) entsteht unter neuem Namen, die ALTE
--   core.fn_set_advisor_cron bliebe sonst verwaist liegen. Dieser einmalige DROP raeumt sie weg
--   (db/CLAUDE.md *Migrations-Modell*; enforcement-Gotcha „fn-Rename braucht V-DROP").
--
--   Der Name wurde generisch, weil die fn laengst nicht nur den Advisor-Cron schaltet, sondern jeden
--   whitelisteten Cron (drift_check|plan_review|learn_context). Signatur/Whitelist/Body unveraendert
--   (R__fn_set_cron_enable.sql), nur der Funktionsname zog um.
--
--   SICHER + IDEMPOTENT: IF EXISTS-geguardet; ein erneuter Lauf ist no-op. Apply-Order Inits->V->R laesst
--   den DROP VOR dem neuen R__ laufen (Drop-alt, dann Create-neu); auf Frisch-Install = No-op-Drop.
--   Der einzige Laufzeit-Aufrufer (Orchestrator-Callback) zieht im selben Phase-D-Commit auf den neuen Namen.
-- ============================================================

DROP FUNCTION IF EXISTS core.fn_set_advisor_cron(jsonb);

-- Verwaiste Repeatable-Ledger-Zeile der umbenannten R__-Datei mitraeumen (kosmetisch; ohne sie kein Fehler,
-- der Treiber iteriert nur ueber on-disk-Dateien). version = relativer Pfad (core.schema_version_init.sql).
DELETE FROM core.schema_version WHERE version LIKE '%R__fn_set_advisor_cron.sql';
