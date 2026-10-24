-- ============================================================
-- V007 (core) — WS2a: die 3 stale finance-Config-Zeilen des abgeloesten
--   Quartals-Crons agent.finance_advisor.cron_plan_review HART entfernen.
--
--   WARUM eine V-Migration (kein Seed): Seeds sind additiv + loeschen NIE (ON CONFLICT
--   DO UPDATE/NOTHING). Die generische Core-Advisor-Engine (WS2) loest den finance-eigenen
--   Cron ab; seine Config-Keys wandern nach core (schedule.drift_check/plan_review,
--   model.advisor_review, cron_enable.drift_check/plan_review). Die schon geseederten
--   finance-Zeilen (package='finance') wuerden sonst als Leichen in core.config bleiben.
--
--   CHIRURGISCH: nur das advisor_plan_review-Triple raus. Die anderen finance-Config-Keys
--   (refresh_fx_rates / remind_recurring / reconcile_accounts + model.* + finance.*) bleiben
--   unangetastet. KEINE Key-Kollision: alt 'advisor_plan_review' != neu 'plan_review'/'drift_check'.
--
--   IDEMPOTENT: V laeuft genau einmal (ledger-gegated). Fresh DB = no-op (die Zeilen wurden
--   dort nie geseedet, weil das finance-Manifest sie nicht mehr deklariert).
--
-- APPLY-ORDER: Inits -> V (hier) -> R. Re-run-sicher.
-- ============================================================

DELETE FROM core.config
WHERE package = 'finance'
  AND key = 'advisor_plan_review'
  AND category IN ('schedule', 'model', 'cron_enable');
