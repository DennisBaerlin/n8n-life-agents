-- ============================================================
-- V021 — agent.advisor_plans.domain ohne 'finance'-Default (Phase B, Core kennt kein Paket)
--   Die Init traegt den Endzustand (NOT NULL ohne Default); Bestands-DBs behalten den alten Spalten-
--   Default bis hierher. Ein Write ohne domain scheitert damit laut (NOT NULL) statt still im Finanzplan
--   zu landen; die freundliche {ok:false}-Meldung liefern fn_advisor_save_section / fn_advisor_publish_plan.
--   Idempotent (DROP DEFAULT auf einer Spalte ohne Default ist ein No-op).
-- ============================================================
ALTER TABLE agent.advisor_plans ALTER COLUMN domain DROP DEFAULT;
