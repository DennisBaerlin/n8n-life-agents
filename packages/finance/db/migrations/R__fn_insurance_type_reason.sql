-- ============================================================
-- fn_insurance_type_reason (READ HELPER) -- insurance_type-Guard fuer fn_create_insurance/fn_set_insurance
--   Die eine Adresse der Liste fuer die Write-fns; Spiegel von finance_insurances_type_chk
--   (Init, struktureller Backstop). Eingabe: p_value. Rueckgabe: NULL bei leerem oder gueltigem Wert, sonst der
--   korrigierbare Grund (EN) mit den erlaubten Werten. Ohne den Guard scheiterte z. B. "Haftpflicht" erst am CHECK ->
--   RAISE/Owner-Alert bzw. Rohfehler nach der Import-Freigabe.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_insurance_type_reason(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN NULLIF(p_value, '') IS NULL
          OR p_value = ANY (ARRAY['life', 'accident', 'disability', 'health', 'care',
                                  'liability', 'household', 'residential_building', 'legal', 'vehicle', 'other']) THEN NULL
        ELSE 'Unknown insurance_type "' || p_value || '" - allowed values: life, accident, disability, health, care, '
             || 'liability, household, residential_building, legal, vehicle, other.'
    END;
$$;
