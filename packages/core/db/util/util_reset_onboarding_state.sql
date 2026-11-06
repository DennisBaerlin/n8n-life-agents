-- ============================================================
-- util_reset_onboarding_state.sql — Onboarding-Fortschritt auf Anfang (alle Sektionen 'unknown')
--   Duenner Wrapper um core.fn_reset_onboarding_state (Core + jedes Paket ueber die <pkg>.onboarding_state-
--   Konvention, Phase B). Zweck: echtes Neu-Onboarding ODER Aufraeumen nach einem Test/Versehen.
--   Schliesst das Advisor-Pflicht-Gate wieder (feature.onboarding_gate vorausgesetzt).
--   Anwenden via: db_apply.ps1 -File packages/core/db/util/util_reset_onboarding_state.sql
-- ============================================================
SELECT core.fn_reset_onboarding_state();
