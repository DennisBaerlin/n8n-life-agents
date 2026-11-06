-- ============================================================
-- V029 (finance) — finance.onboarding_state.skipped_at droppen.
--
--   WARUM (Regel "Keine ableitbaren Spalten"): skipped_at ist ableitbar aus status + status_changed_at und wird seit
--   WP3 von core.fn_set_onboarding_section nicht mehr geschrieben; niemand liest sie. Gleiches Muster wie core:V032
--   (agent.guide_onboarding_state), estate:V002 und career:V007.
--
--   Die Spalte bleibt im Init-CREATE als Geruest stehen, weil core:V003 sie beim frischen Bootstrap noch befuellt
--   (Split-Backfill); diese V droppt sie danach. Re-run-sicher (IF EXISTS).
-- APPLY-ORDER: Inits -> V (hier) -> R -> Seed.
-- ============================================================

ALTER TABLE finance.onboarding_state DROP COLUMN IF EXISTS skipped_at;
