-- ============================================================
-- fn_interest_default_convention (READ — vorgeschlagene day-count-Methode aus dem Kontotyp; DRY-Helfer)
--   Die Zinsmethode wird bei der Anlage NICHT global fix gesetzt, sondern aus dem Kontotyp VORGESCHLAGEN
--   (Owner-Direktive) und im HITL-Gate mit Grund gezeigt; pro Konto ueberschreibbar.
--     cash (Tagesgeld/Giro)      -> 'ACT/365'  (taggenau, Tagesgeld-Standard)
--     fixed_deposit (Festgeld)   -> '30E/360'  (deutsche kaufmaennische Methode)
--     sonst (z. B. p2p)          -> 'ACT/365'  (sicherer Fallback; zins-faehige Typen: fn_interest_eligible_account_type)
--   EINE Adresse fuer den Default -> fn_create_account UND fn_set_account_interest rufen sie (kein Drift).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_default_convention(p_account_type finance.account_type)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_account_type
        WHEN 'fixed_deposit' THEN '30E/360'
        WHEN 'cash'          THEN 'ACT/365'
        ELSE 'ACT/365'
    END;
$$;
