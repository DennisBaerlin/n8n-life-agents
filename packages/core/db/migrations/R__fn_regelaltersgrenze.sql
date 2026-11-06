-- ============================================================
-- fn_regelaltersgrenze (read-only Ableitung, IMMUTABLE)
--   DRV-Stufenplan der Regelaltersgrenze aus dem Geburtsdatum (§ 35, § 235 SGB VI):
--     Jahrgang <  1947: 65 Jahre
--     Jahrgang 1947-1958: 65 Jahre + (Jahrgang-1946) Monate   (1947=+1M ... 1958=+12M=66)
--     Jahrgang 1959-1963: 66 Jahre + 2*(Jahrgang-1958) Monate (1959=+2M ... 1963=+10M)
--     Jahrgang >= 1964: 67 Jahre
--   Rohfakt speichern, Ableitung rechnen: das LLM rechnet NIE Datums-Arithmetik —
--   Konsumenten sind die Render-Fns (fn_household_context) und kuenftige Cron-SQL.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_regelaltersgrenze(p_birth date)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_year INT := EXTRACT(YEAR FROM p_birth)::int;
BEGIN
    RETURN (CASE
        WHEN v_year < 1947  THEN p_birth + INTERVAL '65 years'
        WHEN v_year <= 1958 THEN p_birth + INTERVAL '65 years' + make_interval(months => v_year - 1946)
        WHEN v_year <= 1963 THEN p_birth + INTERVAL '66 years' + make_interval(months => 2 * (v_year - 1958))
        ELSE                     p_birth + INTERVAL '67 years'
    END)::date;
END;
$$;
