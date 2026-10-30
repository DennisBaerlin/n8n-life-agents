-- ============================================================
-- finance.standing_order_overview (Lese-View, Berater-Nachruestung 2026-10-30)
--   Die Dauerauftraege, die der Haushalt bei seiner Bank selbst einrichtet (finance.fn_standing_orders, dieselbe Auswahl
--   wie die Bank-To-do der Seite Ziele: laufend oder erst kommend), mit Konto-NAMEN statt ids, Betrag je Ausfuehrung,
--   Rhythmus in Klartext (fn_schedule_label) und Monatsbetrag (recurring_payments.monthly_equivalent).
--   kind transfer = eigenes Konto -> eigenes Konto; debit = Spar-Abfluss ohne Ziel-Konto (Vorsorge-Beitrag,
--   Sparziel-Rate ohne Topf). starts_on = erst kuenftiger Start (sonst NULL).
--   Bewusst EIGENE Datei (R__v_*, sortiert nach R__fn_*) und nur Tabellen + Funktionen (Muster R__v_savings_plan_overview).
--   Rechte: finance_ro per GRANT SELECT ON ALL TABLES (core.fn_provision_package_roles).
-- ============================================================
DROP VIEW IF EXISTS finance.standing_order_overview CASCADE;
CREATE VIEW finance.standing_order_overview AS
SELECT o.rp_id                                  AS recurring_payment_id,
       o.kind,
       r.name,
       sa.name                                  AS from_account,
       ta.name                                  AS to_account,
       sa.currency,
       abs(r.amount)                            AS amount_per_execution,
       finance.fn_schedule_label(r.schedule_unit, r.schedule_interval, r.schedule_day_of_month,
                                 r.schedule_days_of_month) AS rhythm,
       abs(r.monthly_equivalent)                AS monthly_amount,
       CASE WHEN r.valid_from > current_date THEN r.valid_from END AS starts_on,
       r.valid_to
FROM finance.fn_standing_orders() o
JOIN finance.recurring_payments r ON r.id = o.rp_id
JOIN finance.accounts sa ON sa.id = r.account_id
LEFT JOIN finance.accounts ta ON ta.id = r.target_account_id;
