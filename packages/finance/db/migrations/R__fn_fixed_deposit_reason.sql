-- ============================================================
-- fn_fixed_deposit_reason (READ HELPER — Festgeld-Pflichtangaben)
--   Die eine Regel "ein Festgeld braucht Zinssatz und Faelligkeit". Eingabe: p_rate (0/NULL = fehlt), p_maturity.
--   Rueckgabe: NULL = in Ordnung, sonst der nutzer-korrigierbare Grund (EN, fuer {ok:false, reason}). Konsumenten: fn_create_account (Einzel-Anlage) und
--   fn_import_validate_row (Import-Zeile). Spiegel-CHECK der Faelligkeit: finance_accounts_fixed_deposit_maturity_chk (V020).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_fixed_deposit_reason(p_rate numeric, p_maturity date)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN COALESCE(p_rate, 0) = 0 OR p_maturity IS NULL
                THEN 'A fixed deposit needs its interest rate (interest_rate) and its maturity date (fixed_deposit_maturity_date) - ask the user for the missing value.'
           END;
$$;
