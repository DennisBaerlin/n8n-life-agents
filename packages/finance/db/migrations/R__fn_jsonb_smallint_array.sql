-- ============================================================
-- fn_jsonb_smallint_array (READ — jsonb-Zahlenliste -> smallint[]; JSON null/kein Array -> NULL)
--   Dekodiert die Tage-Listen aus fn_resolve_plan_schedule (schedule_days_of_month, calendar) fuer die Writes;
--   die eine Umwandlung, nicht je Write ein eigener ARRAY(SELECT jsonb_array_elements_text(...)::smallint)-Ausdruck.
--   Eingabe: p (jsonb-Array von Zahlen). Rueckgabe: smallint[]; JSON null oder kein Array -> NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_jsonb_smallint_array(p jsonb)
RETURNS smallint[] LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(p) = 'array'
                THEN ARRAY(SELECT e::smallint FROM jsonb_array_elements_text(p) e) END;
$$;
