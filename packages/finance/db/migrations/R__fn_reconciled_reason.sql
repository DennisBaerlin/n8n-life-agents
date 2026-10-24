-- ============================================================
-- fn_reconciled_reason (READ HELPER) -- Doppelzaehlungs-Sperre gegen den Saldo-Abgleich (Monats-Check WP-A)
--   Ein Saldo-Abgleich zum Stichtag D (fn_reconcile_account: manuell oder per Kontoauszug) bestaetigt den
--   Kontostand inkl. ALLER Bewegungen bis D; die Differenz steckt in der Korrekturbuchung. Eine danach nachgeholte
--   Dauerauftrags-/Zinsbuchung mit Buchungsdatum <= D zaehlte doppelt. Gilt je BEIN-Konto (Transfer: Quelle UND
--   Ziel) und keyt aufs BUCHUNGSdatum, nicht auf die Faelligkeit (Faelligkeit 30.09., abgebucht 01.10. gehoert in den
--   Oktober). EINE Adresse fuer fn_book_recurring_occurrence/_transfer, fn_book_loan_payment, fn_book_stock_buy
--   (Sparplan-Pfad) und fn_book_interest_occurrence.
--   RUECKGABE: NULL = buchbar, sonst der Grund (EN, fuer {ok:false, code:'reconciled', reason}).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reconciled_reason(p_account_id int, p_date date)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT 'Account "' || a.name || '" was already reconciled on ' || a.last_reconciled_at
           || '; that balance already contains every movement up to that day, so a booking dated ' || p_date
           || ' would count twice.'
    FROM finance.accounts a
    WHERE a.id = p_account_id
      AND a.last_reconciled_at IS NOT NULL
      AND p_date <= a.last_reconciled_at;
$$;
