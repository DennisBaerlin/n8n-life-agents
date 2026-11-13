-- ============================================================
-- estate.fn_case_template_rows (READ — die eine Quelle des "Soll-Task-Satzes" eines Falls)
--   Set-returning: liefert fuer gegebene Fall-Fakten (nicht -id: die Preview simuliert einen Fall, der
--   noch nicht existiert) die Tasks, die der Fall haben soll — mit DB-berechneter due_date + Condition-
--   ausgewertetem Status. Eine Quelle fuer beide Konsumenten: fn_instantiate_case_tasks (INSERT
--   ... SELECT ... ON CONFLICT) und fn_preview_case (Zaehlung je Phase vor dem Gate).
--   Eingabe: p_case_type, p_subject (person_id), p_flags (explizite Fall-Angaben), p_event, p_know (Anker-Daten),
--   p_bundesland; p_extra_assets optional (siehe unten).
--   Rueckgabe: Zeilen (template_key, subject_ref, phase, title, detail, due_date, hardness, legal_source,
--   status 'open'|'not_applicable').
--   Condition-Auswertung: NULL=immer; derived (adult_subject = Subjekt keine role='child';
--   finance_absent = finance-Paket nicht aktiv; minor_children = Haushalt hat eine role='child'); sonst
--   ein Intake-Merkmal (tenant/employed/pension_relevant/has_will/no_poa/abroad_or_work_accident): wirksam =
--   estate.fn_case_register_flags (Register-Ableitung) || p_flags (explizite Fall-Angabe schlaegt das Register).
--   Condition FALSE + kein fan_out -> Task als 'not_applicable' sichtbar (nicht still weg). fan_out
--   (special_asset-Typ) -> je passendem Sonderfall-Stub (Subjekt oder Haushalt) eine 'open'-Task
--   (subject_ref='asset:<id>', Titel um die Beschreibung ergaenzt); 0 Stubs -> 0 Tasks.
--   Rolle/Minderjaehrige nur ueber core.fn_household_persons() (DEFINER-Fenster), nie agent.persons
--   direkt (crasht unter estate_rw).
--   p_extra_assets (optional, nur die Preview): Sonderfall-Stubs, die der Fall noch anlegen wird, als Array von
--   {asset_type, description}, bereits normalisiert/dedupliziert (fn_preview_case). Sie zaehlen wie Register-Stubs
--   als offene fan_out-Aufgabe, tragen aber den Platzhalter-Ref 'new:<n>' (nie 'asset:'): der Create-Pfad legt die
--   Stubs an und ruft diese fn ohne Extras, daher landet ein Platzhalter nie in case_tasks.
--   STABLE (liest task_templates + special_assets + DEFINER-Fenster; kein Write).
-- ============================================================
DROP FUNCTION IF EXISTS estate.fn_case_template_rows(text, text, jsonb, date, date, text);   -- Signaturwechsel (7. Parameter), sonst zwei Ueberladungen
CREATE OR REPLACE FUNCTION estate.fn_case_template_rows(
    p_case_type text, p_subject text, p_flags jsonb, p_event date, p_know date, p_bundesland text,
    p_extra_assets jsonb DEFAULT NULL)
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
    -- Wirksame Merkmale = Register-Ableitung (estate.fn_case_register_flags), ueberstimmt von der expliziten
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
            IF jsonb_typeof(p_extra_assets) = 'array' THEN
                FOR a IN
                    SELECT x.e->>'description' AS description, x.ord
                      FROM jsonb_array_elements(p_extra_assets) WITH ORDINALITY x(e, ord)
                     WHERE x.e->>'asset_type' = t.fan_out
                     ORDER BY x.ord
                LOOP
                    RETURN QUERY SELECT t.template_key, ('new:' || a.ord)::text, t.phase,
                                        (t.title || ' — ' || a.description)::text, t.detail, v_due,
                                        t.hardness, t.legal_source, 'open'::text;
                END LOOP;
            END IF;
        END IF;
    END LOOP;
END;
$$;
