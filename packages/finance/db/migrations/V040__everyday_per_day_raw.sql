-- ============================================================
-- V040 (finance) -- fn_account_everyday_per_day: Rueckgabe um per_day_raw (ungerundeter Tageswert) erweitert.
--
--   Der Monatswert der View finance.account_everyday_spending rechnete aus dem schon auf Cent gerundeten Tageswert
--   (bis zu 0,005 x 30,44 = 0,15 Abweichung je Konto); er braucht den ungerundeten Wert. Eine geaenderte
--   OUT-Spaltenliste geht nicht per CREATE OR REPLACE; das DROP ... CASCADE reisst die View mit, darum einmalig hier
--   (Begruendung wie V034). Danach bauen R__fn_account_everyday_per_day und R__v_account_everyday_spending (im selben
--   Commit geaendert -> neue Checksumme) beide neu. Frische DB: fn existiert noch nicht -> No-op. Re-run-sicher.
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'finance' AND p.proname = 'fn_account_everyday_per_day'
                  AND NOT ('per_day_raw' = ANY (COALESCE(p.proargnames, '{}')))) THEN
        DROP FUNCTION finance.fn_account_everyday_per_day(int) CASCADE;
    END IF;
END $$;
