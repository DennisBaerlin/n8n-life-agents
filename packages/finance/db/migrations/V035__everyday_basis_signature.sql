-- ============================================================
-- V035 (finance) — fn_account_everyday_basis: Rueckgabe um oneoff_out/oneoff_threshold erweitert (einmalige
--   Grossausgaben, Owner-Entscheid 2026-10-30).
--
--   Eine geaenderte OUT-Spaltenliste geht nicht per CREATE OR REPLACE. Keine View haengt an der fn (Konsumenten sind die
--   plpgsql-fns fn_account_everyday_per_day und fn_app_screen_payments, spaet gebunden) -> DROP ohne CASCADE. Einmalig
--   hier statt in der R__-Datei (Muster V034): nur wenn die alte Signatur (ohne oneoff_out) installiert ist; danach baut
--   R__fn_account_everyday_basis die fn per CREATE OR REPLACE. Frische DB: die fn existiert noch nicht -> No-op.
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'finance' AND p.proname = 'fn_account_everyday_basis'
                  AND NOT ('oneoff_out' = ANY (COALESCE(p.proargnames, '{}')))) THEN
        DROP FUNCTION finance.fn_account_everyday_basis(int);
    END IF;
END $$;
