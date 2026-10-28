-- ============================================================
-- finance.depot_performance (Lese-View, Depot-Rendite)
--   EINE Zeile je aktivem Depot + EINE Gesamt-Zeile (is_total, ohne Kinder-Depots) aus finance.fn_depot_performance
--   (Haushalts-Sicht, Stichtag heute): Wert, Beginn, geldgewichtete Rendite (XIRR) — return_pa_pct ab 365 Tagen,
--   darunter nur return_since_start_pct (nicht annualisiert), missing_reason statt einer erfundenen Zahl. Der Agent
--   liest die Depot-Rendite hier und rechnet nie selbst.
--   Bewusst EIGENE Datei (R__v_*, sortiert nach R__fn_*): die View braucht die fn, die alphabetisch nach
--   R__finance_views liegt; Muster R__v_savings_plan_overview.sql.
--   Rechte: finance_ro per GRANT SELECT ON ALL TABLES (core.fn_provision_package_roles); die fn ist INVOKER mit
--   PUBLIC-EXECUTE und liest nur, was finance_ro lesen darf (+ core.fn_household_persons).
-- ============================================================
DROP VIEW IF EXISTS finance.depot_performance CASCADE;
CREATE VIEW finance.depot_performance AS
SELECT r.account_id,
       r.depot_name,
       r.owner_person_id,
       r.is_child,
       r.is_total,
       r.value_eur,
       r.start_date,
       r.period_days,
       r.return_pa_pct,
       r.return_since_start_pct,
       r.takeover_start_date,
       r.missing_reason
FROM jsonb_to_recordset(finance.fn_depot_performance('{}'::jsonb) -> 'rows') AS r(
       account_id int, depot_name text, owner_person_id text, is_child boolean, is_total boolean, value_eur numeric,
       start_date date, period_days int, return_pa_pct numeric, return_since_start_pct numeric,
       takeover_start_date date, missing_reason text);
