-- ============================================================
-- V020 (finance) — spiegelnder CHECK zu fn_create_account (Paket DB-ist-das-Gesetz S4, 2026-10-23):
--   ein Festgeld (account_type = 'fixed_deposit') traegt ein Faelligkeitsdatum. Vorher stand die Pflicht nur in der
--   Tool-Description; ohne Datum gibt es weder Faelligkeits-Hinweis noch Zins-Ende. Der Zinssatz liegt in
--   account_interest_rates (anderer Tabelle) -> den erzwingt fn_create_account selbst ({ok:false}).
--
--   PRE-FLIGHT (fail-loud, Muster V018): ein aktives Bestands-Festgeld ohne Datum bricht die Migration mit ids ab —
--   still ein Datum erfinden waere schlimmer. Korrektur: set_account mit dem Faelligkeitsdatum, dann erneut migrieren.
--   Geschlossene Festgelder sind ausgenommen (Historie).
--   APPLY-ORDER: Inits -> V (hier) -> R. Re-run-sicher (DROP CONSTRAINT IF EXISTS + ADD).
-- ============================================================

-- (1) Pre-Flight
DO $$
DECLARE v_bad TEXT;
BEGIN
    SELECT string_agg(id::text || ' (' || name || ')', ', ' ORDER BY id) INTO v_bad
      FROM finance.accounts
     WHERE account_type = 'fixed_deposit' AND status = 'active' AND fixed_deposit_maturity_date IS NULL;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'V020 pre-flight: aktive Festgeld-Konten ohne Faelligkeitsdatum: %. Das Datum per set_account nachtragen, dann erneut migrieren.', v_bad;
    END IF;
END $$;

-- (2) CHECK
DO $$ BEGIN
    ALTER TABLE finance.accounts DROP CONSTRAINT IF EXISTS finance_accounts_fixed_deposit_maturity_chk;
    ALTER TABLE finance.accounts ADD CONSTRAINT finance_accounts_fixed_deposit_maturity_chk
        CHECK (account_type <> 'fixed_deposit' OR status <> 'active' OR fixed_deposit_maturity_date IS NOT NULL);
END $$;
