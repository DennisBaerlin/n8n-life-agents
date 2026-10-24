-- ============================================================
-- estate.fn_instantiate_case_tasks (WS-3 — interner Materialisierer, kein Agent-Tool)
--   Schreibt/aktualisiert die case_tasks eines Falls aus dem Soll-Satz (fn_case_template_rows). EINE
--   Logik fuer BEIDE Aufrufer (DRY): fn_create_case (frischer Fall -> alles INSERT) und fn_set_case
--   (Reconcile nach knowledge/bundesland/flags-Aenderung). Das ON CONFLICT deckt beide:
--     * due_date wird IMMER neu berechnet (bundesland/knowledge-Aenderung schlaegt auf offene Fristen).
--     * ADDITIVER Reconcile: eine 'not_applicable'-Task, deren Condition jetzt zutrifft, kippt auf
--       'open' (excluded.status). NICHTS wird auto-n.a. (open/done bleiben unveraendert — dokumentierte
--       Grenze: eine wieder-unzutreffende Task bleibt sichtbar offen, statt still zu verschwinden).
--     * title/detail = SNAPSHOT (beim ersten Insert eingefroren, nie ueberschrieben — der Katalog darf
--       sich aendern, die laufende Checkliste bleibt stabil).
--   Manuelle Tasks (template_key NULL) sind NICHT im Soll-Satz -> vom Reconcile nie beruehrt.
--   SECURITY INVOKER (laeuft unter estate_rw des Aufrufers; alle Refs schema-qualifiziert).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_instantiate_case_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_instantiate_case_tasks(p_case_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_type    TEXT; v_subject TEXT; v_event DATE; v_know DATE; v_bl TEXT; v_flags JSONB;
BEGIN
    SELECT case_type, subject_person_id, event_date, knowledge_date, bundesland, flags
      INTO v_type, v_subject, v_event, v_know, v_bl, v_flags
      FROM estate.cases WHERE id = p_case_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'estate.fn_instantiate_case_tasks: case % not found', p_case_id;
    END IF;

    INSERT INTO estate.case_tasks
        (case_id, template_key, subject_ref, phase, title, detail, due_date, hardness, legal_source, status)
    SELECT p_case_id, r.template_key, r.subject_ref, r.phase, r.title, r.detail, r.due_date,
           r.hardness, r.legal_source, r.status
    FROM estate.fn_case_template_rows(v_type, v_subject, v_flags, v_event, v_know, v_bl) r
    ON CONFLICT (case_id, template_key, subject_ref) DO UPDATE SET
        due_date   = excluded.due_date,
        status     = CASE WHEN case_tasks.status = 'not_applicable' THEN excluded.status
                          ELSE case_tasks.status END,
        updated_at = now();
END;
$$;
