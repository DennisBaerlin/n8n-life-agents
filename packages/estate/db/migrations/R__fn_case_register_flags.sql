-- ============================================================
-- estate.fn_case_register_flags (WP3 — Fall-Merkmale aus dem Vorsorge-Register ABLEITEN, nie erfragen/speichern)
--   Liefert je Intake-Merkmal true | false | null (null = das Register weiss es nicht -> der Agent fragt genau das).
--   Muster wie die DERIVED-Conditions adult_subject/minor_children in fn_case_template_rows: der Fall speichert nur,
--   was der Nutzer ausdruecklich sagt (cases.flags = Override), alles andere kommt live aus dem Register.
--     has_will         true : testament ODER erbvertrag 'exists'
--                      false: testament 'does_not_exist' und kein erbvertrag 'exists'/'planned'
--     no_poa           true : vorsorgevollmacht 'does_not_exist' (und keine 'exists');  false: 'exists'
--     employed         true : person_records.employer gesetzt ODER ein employer_hr-Kontakt des Subjekts
--     pension_relevant true : person_records.pension_insurance_no gesetzt
--     tenant           true : ein landlord-Kontakt (Subjekt oder Haushalt)
--   Urkunden/Kontakte des Haushalts (owner_person_id NULL, z. B. Berliner Testament) zaehlen nur fuer ein
--   ERWACHSENES Subjekt (owner/partner). Fuer ein Kind sind employed/pension_relevant/tenant/no_poa abgeleitet false
--   (Eltern vertreten ein minderjaehriges Kind kraft Sorgerecht; es arbeitet/mietet nicht).
--   Rolle NUR ueber core.fn_household_persons() (DEFINER-Fenster, D10). STABLE, kein Write.
--   Tests: tests/db/estate/test_fn_case_register_flags.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_case_register_flags(p_subject text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_role   TEXT;
    v_adult  BOOLEAN;
    v_child  BOOLEAN;
    v_will   JSONB := 'null'::jsonb;
    v_poa    JSONB := 'null'::jsonb;
    v_emp    JSONB := 'null'::jsonb;
    v_pen    JSONB := 'null'::jsonb;
    v_ten    JSONB := 'null'::jsonb;
BEGIN
    SELECT role INTO v_role FROM core.fn_household_persons() WHERE person_id = p_subject;
    v_child := v_role = 'child';
    v_adult := COALESCE(v_role, 'partner') <> 'child';

    -- Urkunden des Subjekts bzw. (nur Erwachsene) des Haushalts
    IF EXISTS (SELECT 1 FROM estate.directives d
                WHERE d.doc_type IN ('testament', 'erbvertrag') AND d.doc_status = 'exists'
                  AND (d.owner_person_id = p_subject OR (d.owner_person_id IS NULL AND v_adult))) THEN
        v_will := 'true'::jsonb;
    ELSIF EXISTS (SELECT 1 FROM estate.directives d
                   WHERE d.doc_type = 'testament' AND d.doc_status = 'does_not_exist'
                     AND (d.owner_person_id = p_subject OR (d.owner_person_id IS NULL AND v_adult)))
      AND NOT EXISTS (SELECT 1 FROM estate.directives d
                       WHERE d.doc_type = 'erbvertrag' AND d.doc_status IN ('exists', 'planned')
                         AND (d.owner_person_id = p_subject OR (d.owner_person_id IS NULL AND v_adult))) THEN
        v_will := 'false'::jsonb;
    END IF;

    IF v_child THEN
        v_poa := 'false'::jsonb;
    ELSIF EXISTS (SELECT 1 FROM estate.directives d
                   WHERE d.doc_type = 'vorsorgevollmacht' AND d.doc_status = 'exists'
                     AND (d.owner_person_id = p_subject OR d.owner_person_id IS NULL)) THEN
        v_poa := 'false'::jsonb;
    ELSIF EXISTS (SELECT 1 FROM estate.directives d
                   WHERE d.doc_type = 'vorsorgevollmacht' AND d.doc_status = 'does_not_exist'
                     AND (d.owner_person_id = p_subject OR d.owner_person_id IS NULL)) THEN
        v_poa := 'true'::jsonb;
    END IF;

    IF v_child THEN
        v_emp := 'false'::jsonb;
        v_pen := 'false'::jsonb;
        v_ten := 'false'::jsonb;
    ELSE
        IF EXISTS (SELECT 1 FROM estate.person_records pr
                    WHERE pr.person_id = p_subject AND NULLIF(trim(pr.employer), '') IS NOT NULL)
           OR EXISTS (SELECT 1 FROM estate.contacts c
                       WHERE c.role = 'employer_hr' AND c.owner_person_id = p_subject) THEN
            v_emp := 'true'::jsonb;
        END IF;
        IF EXISTS (SELECT 1 FROM estate.person_records pr
                    WHERE pr.person_id = p_subject AND pr.pension_insurance_no IS NOT NULL) THEN
            v_pen := 'true'::jsonb;
        END IF;
        IF EXISTS (SELECT 1 FROM estate.contacts c
                    WHERE c.role = 'landlord' AND (c.owner_person_id = p_subject OR c.owner_person_id IS NULL)) THEN
            v_ten := 'true'::jsonb;
        END IF;
    END IF;

    RETURN jsonb_build_object('has_will', v_will, 'no_poa', v_poa, 'employed', v_emp,
                              'pension_relevant', v_pen, 'tenant', v_ten);
END;
$$;
