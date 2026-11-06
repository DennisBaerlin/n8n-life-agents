-- ============================================================
-- V034 (finance) — fn_account_everyday_per_day: Rueckgabe um provisional erweitert (Transparenz 2026-10-30).
--
--   Eine geaenderte OUT-Spaltenliste geht nicht per CREATE OR REPLACE; das DROP ... CASCADE reisst die abhaengige View
--   finance.account_everyday_spending (eigene Datei R__v_account_everyday_spending.sql) mit. Stuende das DROP in der
--   R__-Datei der fn, verloere jede spaetere Aenderung NUR dieser Datei die View still (ihre Checksumme bliebe gleich ->
--   kein Neubau; docs/reference/packages.md "View-Familie"). Darum einmalig hier: nur wenn die alte Signatur (ohne
--   provisional) installiert ist. Danach baut R__fn_account_everyday_per_day die fn per CREATE OR REPLACE und
--   R__v_account_everyday_spending (im selben Release geaendert -> neue Checksumme) die View neu.
--   Frische DB: die fn existiert hier noch nicht -> No-op. Re-run-sicher.
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'finance' AND p.proname = 'fn_account_everyday_per_day'
                  AND NOT ('provisional' = ANY (COALESCE(p.proargnames, '{}')))) THEN
        DROP FUNCTION finance.fn_account_everyday_per_day(int) CASCADE;
    END IF;
END $$;
