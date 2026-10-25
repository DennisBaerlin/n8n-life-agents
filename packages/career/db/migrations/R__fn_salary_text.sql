-- ============================================================
-- career.fn_salary_text (Gehalt mit Einheit als Anzeige-Text fuer die Fakten-Header)
--   "4000 € netto/Monat (≈ 48000 € netto/Jahr)", "75000 € brutto/Jahr"; ohne Basis "…; brutto/netto offen", ohne
--   Einheit (Bestand vor WP3) "60000 € (Einheit offen)" — nie eine angenommene Einheit. Den Jahreswert rechnet
--   career.fn_salary_annual; brutto/netto wird nie umgerechnet. Ohne Betrag -> NULL.
--   plpgsql (late-bound: ruft die alphabetisch fruehere career.fn_salary_annual, aber robust gegen Umsortierung).
--   IMMUTABLE. Tests: tests/db/career/test_fn_salary_text.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_salary_text(p_amount numeric, p_period text, p_basis text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_basis  text := CASE p_basis WHEN 'gross' THEN 'brutto' WHEN 'net' THEN 'netto' END;
    v_annual numeric;
BEGIN
    IF p_amount IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_period NOT IN ('month', 'year') OR p_period IS NULL THEN
        RETURN p_amount::text || ' € (Einheit offen)';
    END IF;
    v_annual := career.fn_salary_annual(p_amount, p_period);
    IF p_period = 'year' THEN
        RETURN p_amount::text || ' €' || COALESCE(' ' || v_basis, '') || '/Jahr'
            || CASE WHEN v_basis IS NULL THEN ' (brutto/netto offen)' ELSE '' END;
    END IF;
    RETURN p_amount::text || ' €' || COALESCE(' ' || v_basis, '') || '/Monat (≈ '
        || round(v_annual)::text || ' €' || COALESCE(' ' || v_basis, '') || '/Jahr'
        || CASE WHEN v_basis IS NULL THEN '; brutto/netto offen' ELSE '' END || ')';
END;
$$;
