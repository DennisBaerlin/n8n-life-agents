-- ============================================================
-- V023 (finance) — Restschuld-Eroeffnung laufender Kredite auf ihren Stichtag (Anlage-Tag) umdatieren.
--
--   WARUM: Live-Befund 2026-10-24 — fn_create_loan buchte die HEUTIGE Restschuld eines laufenden Kredits
--   (current_balance < original_amount) mit transaction_date = disbursement_date. fn_get_balance_as_of(Kreditkonto, d)
--   lieferte so fuer jeden Tag zwischen Auszahlung und Anlage schon die heutige Restschuld; ein Stichtags-Abgleich gegen
--   einen alten Darlehensauszug haette eine falsche Korrektur gebucht. Seit dem Fix bucht fn_create_loan zum Stichtag
--   heute und setzt accounts.opening_balance_date (Analog fn_create_account). Hier einmalig der Bestand:
--     Kandidat = die EINBEINIGE Eroeffnung (category 'disbursement', loan_id gesetzt, auf dem Kreditkonto, Betrag ungleich
--       -original_amount, keine weitere Zeile derselben group_id) mit Datum VOR dem Ziel.
--     Ziel = Anlage-Tag des Kredits in Haushalts-Zeitzone, hoechstens das frueheste Datum einer ANDEREN Buchung auf dem
--       Kreditkonto (sonst stuende die Saldo-Historie davor kurz im Plus).
--     (1) Eroeffnung auf das Ziel datieren; fehlende group_id stempeln (eine eigene je Zeile), damit der Void-Fallback
--         fuer Altdaten (loan_id, transaction_date) die Eroeffnung nicht mit Raten desselben Tags gruppiert.
--     (2) Kreditkonto opening_balance_date = Ziel.
--     (3) Kopf-Kreditrate valid_from = Ziel, wenn sie frueher beginnt und vor dem Ziel noch kein Vorkommen gebucht ist
--         (fruehere Raten stecken in der Restschuld; wie fn_create_loan ueber fn_recurring_valid_from).
--   "Heute zum Anlagezeitpunkt" steht INLINE wie core.fn_today(created_at): V laeuft vor den R__-fns (core.fn_today ist
--   ein R__) -> ein Aufruf scheiterte auf einer frischen DB schon beim Parsen.
--   Generische Regel ohne Werte; Fresh-DB: keine Zeilen -> No-Op. Re-run-sicher (nur Datum < Ziel wird bewegt).
-- ============================================================

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT t.id AS tx_id, l.loan_account_id, l.recurring_payment_id,
               LEAST((l.created_at AT TIME ZONE pg_catalog.current_setting('TimeZone'))::date,   -- wie core.fn_today(created_at)
                     COALESCE((SELECT min(o.transaction_date) FROM finance.transactions o
                               WHERE o.account_id = l.loan_account_id AND o.id <> t.id), 'infinity'::date)) AS target,
               t.transaction_date
        FROM finance.loans l
        JOIN finance.transactions t
          ON t.loan_id = l.id AND t.account_id = l.loan_account_id AND t.category::text = 'disbursement'
        WHERE (l.original_amount IS NULL OR t.amount <> -l.original_amount)
          AND NOT EXISTS (SELECT 1 FROM finance.transactions g
                          WHERE t.group_id IS NOT NULL AND g.group_id = t.group_id AND g.id <> t.id)
    LOOP
        CONTINUE WHEN r.transaction_date >= r.target;

        UPDATE finance.transactions
           SET transaction_date = r.target, group_id = COALESCE(group_id, gen_random_uuid())
         WHERE id = r.tx_id;

        UPDATE finance.accounts
           SET opening_balance_date = r.target
         WHERE id = r.loan_account_id AND (opening_balance_date IS NULL OR opening_balance_date < r.target);

        UPDATE finance.recurring_payments rp
           SET valid_from = r.target
         WHERE rp.id = r.recurring_payment_id AND rp.valid_from < r.target
           AND NOT EXISTS (SELECT 1 FROM finance.transactions x
                           WHERE x.recurring_payment_id = rp.id AND x.recurring_due_date < r.target);
    END LOOP;
END $$;
