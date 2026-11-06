-- ============================================================
-- estate.fn_case_template_rows (WS-3 — die EINE Quelle des "Soll-Task-Satzes" eines Falls)
--   Set-returning: liefert fuer gegebene Fall-FAKTEN (nicht -id: die Preview simuliert einen Fall, der
--   noch nicht existiert) die Tasks, die der Fall haben SOLL — mit DB-berechneter due_date + Condition-
--   ausgewertetem Status. EINE Quelle fuer BEIDE Konsumenten (DRY): fn_instantiate_case_tasks (INSERT
--   ... SELECT ... ON CONFLICT) UND fn_preview_case (Zaehlung je Phase VOR dem Gate).
--   Condition-Auswertung: NULL=immer; DERIVED (adult_subject = Subjekt keine role='child';
--   finance_absent = finance-Paket nicht aktiv; minor_children = Haushalt hat eine role='child'); sonst
--   ein Intake-Merkmal (tenant/employed/pension_relevant/has_will/no_poa/abroad_or_work_accident): WIRKSAM =
--   estate.fn_case_register_flags (Register-Ableitung) || p_flags (explizite Fall-Angabe schlaegt das Register). Condition FALSE + KEIN fan_out -> Task als 'not_applicable' SICHTBAR
--   (nicht still weg). fan_out (special_asset-Typ) -> je passendem Sonderfall-Stub (Subjekt ODER
--   Haushalt) eine 'open'-Task (subject_ref='asset:<id>', Titel um die Beschreibung ergaenzt); 0 Stubs
--   -> 0 Tasks. Rolle/Minderjaehrige NUR ueber core.fn_household_persons() (DEFINER-Fenster) — NIE
--   agent.persons direkt (D10: crasht unter estate_rw).
--   STABLE (liest task_templates + special_assets + DEFINER-Fenster; kein Write).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_case_template_rows.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_case_template_rows(
    p_case_type text, p_subject text, p_flags jsonb, p_event date, p_know date, p_bundesland text)
RETURNS TABLE (
    template_key text, subject_ref text, phase text, title text, detail text,
    due_date date, hardness text, legal_source text, status text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_subject_role TEXT;
    v_has_minor    BOOLEAN;
    v_fin_absent   BOOLEAN := NOT core.fn_package_active('finance');
    t              RECORD;
    a              RECORD;
    v_applicable   BOOLEAN;
    v_anchor       DATE;
    v_due          DATE;
    v_flags        JSONB;
BEGIN
    SELECT role INTO v_subject_role FROM core.fn_household_persons() WHERE person_id = p_subject;
    SELECT EXISTS (SELECT 1 FROM core.fn_household_persons() WHERE role = 'child') INTO v_has_minor;
    -- WP3: wirksame Merkmale = Register-Ableitung (estate.fn_case_register_flags), ueberstimmt von der expliziten
    -- Fall-Angabe (cases.flags = nur Nutzer-Aussagen). null im Register = unbekannt -> faellt weg (Bedingung false).
    v_flags := jsonb_strip_nulls(estate.fn_case_register_flags(p_subject)) || COALESCE(p_flags, '{}'::jsonb);

    FOR t IN
        SELECT * FROM estate.task_templates
        WHERE case_type = p_case_type AND NOT retired
        ORDER BY ord
    LOOP
        v_anchor := CASE t.deadline_anchor WHEN 'knowledge' THEN p_know ELSE p_event END;
        v_due    := estate.fn_compute_due_date(v_anchor, t.offset_count, t.offset_unit, p_bundesland);

        v_applicable := CASE
            WHEN t.condition_key IS NULL            THEN TRUE
            WHEN t.condition_key = 'adult_subject'  THEN COALESCE(v_subject_role, 'partner') IS DISTINCT FROM 'child'
            WHEN t.condition_key = 'finance_absent' THEN v_fin_absent
            WHEN t.condition_key = 'minor_children' THEN v_has_minor
            ELSE COALESCE(v_flags->>t.condition_key = 'true', FALSE)
        END;

        IF t.fan_out IS NULL THEN
            RETURN QUERY SELECT t.template_key, ''::text, t.phase, t.title, t.detail, v_due,
                                t.hardness, t.legal_source,
                                CASE WHEN v_applicable THEN 'open' ELSE 'not_applicable' END::text;
        ELSIF v_applicable THEN
            FOR a IN
                SELECT id, description FROM estate.special_assets
                WHERE asset_type = t.fan_out
                  AND (owner_person_id = p_subject OR owner_person_id IS NULL)
                ORDER BY id
            LOOP
                RETURN QUERY SELECT t.template_key, ('asset:' || a.id)::text, t.phase,
                                    (t.title || ' — ' || a.description)::text, t.detail, v_due,
                                    t.hardness, t.legal_source, 'open'::text;
            END LOOP;
        END IF;
    END LOOP;
END;
$$;
