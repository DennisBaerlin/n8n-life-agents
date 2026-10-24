-- ============================================================
-- V016 (finance) — Monats-Check WP-D: die Config-Zeilen der abgeschafften taeglichen Dauerauftrags-Frage
--   (agent.finance.cron_remind_recurring, Tombstone im Manifest) und die abgeloeste Tages-Schwelle der
--   Abgleich-Erinnerung HART entfernen.
--
--   WARUM eine V-Migration (Muster core V007): Seeds sind additiv und loeschen nie. Die Monats-Check-Erinnerung
--   (cron_reconcile_accounts) fragt jetzt nach dem Kontoauszug jedes Kontos, dessen Stand fuer den letzten Monat noch
--   nicht bestaetigt ist — eine Tages-Schwelle (reconcile_overdue_days) gibt es nicht mehr.
--   CHIRURGISCH: nur diese drei Zeilen; IDEMPOTENT (ledger-gegated, Fresh DB = no-op).
-- ============================================================

DELETE FROM core.config
WHERE package = 'finance'
  AND (   (category IN ('schedule', 'cron_enable') AND key = 'remind_recurring')
       OR (category = 'finance' AND key = 'reconcile_overdue_days'));
