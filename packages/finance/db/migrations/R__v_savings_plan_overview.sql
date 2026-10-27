-- ============================================================
-- finance.savings_plan_overview (Lese-View, Livebefund 2026-10-27)
--   EINE Zeile je Sparplan mit den Bedingungen in Klartext: Betrag JE AUSFUEHRUNG, Rhythmus (fn_schedule_label),
--   Monatsbetrag (recurring_payments.monthly_equivalent), naechste Ausfuehrung. Anlass: der Agent las einen
--   woechentlichen Trade-Republic-Plan (month/1 + Tage {2,9,16,23}, amount -50) aus recurring_payments als
--   "50 pro Monat". Der Agent liest Sparplaene hier, nie aus den Rohtabellen.
--   Bedingungen aus dem HEUTE gueltigen Glied der Raten-Kette (fn_recurring_current; vor dem Start = Kopf ->
--   starts_on). Eine geplante Aenderung (Kopf <> heute gueltiges Glied, Validity-Split mit kuenftigem Stichtag)
--   steht in change_from / new_amount_per_execution / new_rhythm.
--   next_execution kettenbewusst (nur aktive Plaene): erster Rasterpunkt des heute gueltigen Glieds ab
--   max(heute, juengste erledigte Ausfuehrung der Kette + 1, valid_from) vor dessen valid_to, sonst der des Kopfs.
--   Bewusst EIGENE Datei (R__v_*, sortiert nach R__fn_*) und NUR Tabellen + Funktionen, keine Views aus
--   R__finance_views: deren DROP ... CASCADE wuerde diese View sonst still mitreissen (Repeatables laufen nur bei
--   eigener Checksum-Aenderung). Das Aktiv-Praedikat von active_recurring_payments ist deshalb hier nicht noetig:
--   status kommt aus dem Plan (eine Quelle fuer pausiert/aktiv, fn_set_savings_plan kaskadiert auf die rp).
--   Rechte: finance_ro per GRANT SELECT ON ALL TABLES (core.fn_provision_package_roles).
-- ============================================================
DROP VIEW IF EXISTS finance.savings_plan_overview CASCADE;
CREATE VIEW finance.savings_plan_overview AS
WITH chain AS (
    -- je Plan: Kopf + heute gueltiges Glied + Suchbeginn der naechsten Ausfuehrung
    SELECT sp.id AS plan_id,
           h.id AS head_id,
           c.id AS cur_id,
           greatest(current_date, finance.fn_recurring_last_done(c.id) + 1, c.valid_from) AS next_from
    FROM finance.savings_plans AS sp
    INNER JOIN finance.recurring_payments AS h ON h.id = finance.fn_recurring_lineage_head(sp.recurring_payment_id)
    INNER JOIN finance.recurring_payments AS c ON c.id = finance.fn_recurring_current(sp.recurring_payment_id, current_date)
)
SELECT sp.id,
       sp.name,
       sp.status,
       sp.depot_id,
       d.name                                   AS depot_name,
       c.account_id                             AS settlement_account_id,
       s.name                                   AS settlement_account_name,
       s.currency,
       sp.symbol,
       sp.isin,
       sp.security_name,
       sp.asset_class,
       sp.beneficiary_person_id,
       sp.savings_goal_id,
       g.name                                   AS savings_goal_name,
       abs(c.amount)                            AS amount_per_execution,
       finance.fn_schedule_label(c.schedule_unit, c.schedule_interval, c.schedule_day_of_month,
                                 c.schedule_days_of_month) AS rhythm,
       abs(c.monthly_equivalent)                AS monthly_amount,
       CASE WHEN c.valid_from > current_date THEN c.valid_from END AS starts_on,
       CASE WHEN sp.status = 'active' THEN coalesce(
           (SELECT min(o.d)
              FROM finance.fn_schedule_occurrences(c.first_payment_date, c.schedule_interval, c.schedule_unit,
                       c.schedule_day_of_month, c.schedule_days_of_month, ch.next_from, ch.next_from + 400) AS o(d)
             WHERE c.valid_to IS NULL OR o.d < c.valid_to),
           (SELECT min(o.d)
              FROM finance.fn_schedule_occurrences(h.first_payment_date, h.schedule_interval, h.schedule_unit,
                       h.schedule_day_of_month, h.schedule_days_of_month,
                       greatest(ch.next_from, h.valid_from), greatest(ch.next_from, h.valid_from) + 400) AS o(d)
             WHERE h.id <> c.id AND (h.valid_to IS NULL OR o.d < h.valid_to)))
       END                                      AS next_execution,
       CASE WHEN h.id <> c.id THEN h.valid_from END AS change_from,
       CASE WHEN h.id <> c.id THEN abs(h.amount) END AS new_amount_per_execution,
       CASE WHEN h.id <> c.id THEN finance.fn_schedule_label(h.schedule_unit, h.schedule_interval,
                                       h.schedule_day_of_month, h.schedule_days_of_month) END AS new_rhythm,
       sp.recurring_payment_id
FROM finance.savings_plans AS sp
INNER JOIN chain AS ch                    ON ch.plan_id = sp.id
INNER JOIN finance.recurring_payments AS h ON h.id = ch.head_id
INNER JOIN finance.recurring_payments AS c ON c.id = ch.cur_id
INNER JOIN finance.accounts AS d          ON d.id = sp.depot_id
INNER JOIN finance.accounts AS s          ON s.id = c.account_id
LEFT JOIN finance.savings_goals AS g      ON g.id = sp.savings_goal_id;
