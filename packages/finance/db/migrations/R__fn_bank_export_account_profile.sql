-- ============================================================
-- fn_bank_export_account_profile (READ, STABLE) -- Datei-Import-Profil eines Kontos oder NULL
--   Ein Konto "kann Datei-Import", wenn seine Bank (sonst sein Name) zum bank_pattern eines Profils aus
--   fn_bank_export_profiles passt. Leser: Monats-Erinnerung (cron.reconcile_accounts: Schritt-Text Datei statt PDF).
--   plpgsql (late-bound): fn_bank_export_profiles liegt alphabetisch spaeter.
--   RUECKGABE: Profil-key (text) | NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_account_profile(p_account_id int)
RETURNS text LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (SELECT pr->>'key'
            FROM finance.accounts a
            CROSS JOIN LATERAL jsonb_array_elements(finance.fn_bank_export_profiles()) pr
            WHERE a.id = p_account_id
              AND COALESCE(NULLIF(trim(a.bank), ''), a.name) ~* (pr->>'bank_pattern')
            LIMIT 1);
END;
$$;
