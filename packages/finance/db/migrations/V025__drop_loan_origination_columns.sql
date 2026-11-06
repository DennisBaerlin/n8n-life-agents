-- ============================================================
-- V025 (finance) — GENERATED-Spalten aus Ursprungswerten am Kredit entfernen.
--
--   WARUM: Live-Befund 2026-10-24 — bei einem laufenden Kredit passt die "anfaengliche Tilgung" eines alten Angebots
--   nicht zur tatsaechlichen Rate (und ist nicht pruefbar); die Rate ist die Wahrheit. annuity_rate (Zins + Tilgung),
--   origination_monthly_interest und origination_monthly_principal rechneten aus original_amount/principal_rate und
--   standen in loan_overview/loan_summary neben den richtigen, aus der Restschuld gerechneten Werten
--   (monthly_*_current, fn_loan_monthly_interest) -> zwei Wahrheiten. Etablierte Tools (GnuCash, KMyMoney, YNAB)
--   rechnen den Split immer aus der aktuellen Restschuld; original_amount/principal_rate bleiben informativ.
--
--   Die Views haengen an den Spalten -> loan_overview CASCADE droppen (Muster V006; keine Views anderer Pakete haengen
--   daran); R__finance_views.sql legt alle finance-Views danach ohne die Spalten neu an (Grants: util_* zuletzt).
--   Re-run-sicher (IF EXISTS). APPLY-ORDER: Inits -> V (hier) -> R (Views/fns).
-- ============================================================

DROP VIEW IF EXISTS finance.loan_overview CASCADE;

ALTER TABLE finance.loans
    DROP COLUMN IF EXISTS annuity_rate,
    DROP COLUMN IF EXISTS origination_monthly_interest,
    DROP COLUMN IF EXISTS origination_monthly_principal;
