-- finance:V015 — Monats-Check WP-A: der Doppelbuchungs-Riegel fuer Dauerauftrags-Vorkommen keyt jetzt auf die
-- Faelligkeit (finance_transactions_recurring_due_uq auf recurring_payment_id, recurring_due_date, account_id; im Init
-- nach dem Backfill angelegt). Der Vorgaenger auf transaction_date wuerde eine Buchung am Ist-Datum (Faelligkeit
-- 01.10., abgebucht 02.10.) neben einer gleichdatierten Faelligkeit faelschlich abweisen -> entfernen.
DROP INDEX IF EXISTS finance.finance_transactions_recurring_occurrence_uq;
