-- ============================================================
-- estate.fn_instantiate_case_tasks (WS-3 — interner Materialisierer, kein Agent-Tool)
--   Schreibt/aktualisiert die case_tasks eines Falls aus dem Soll-Satz (fn_case_template_rows). EINE
--   Logik fuer BEIDE Aufrufer (DRY): fn_create_case (frischer Fall -> alles INSERT) und fn_set_case
--   (Reconcile nach knowledge/bundesland/flags-Aenderung). Das ON CONFLICT deckt beide:
--     * due_date wird IMMER neu berechnet (bundesland/knowledge-Aenderung schlaegt auf offene Fristen).
--     * Reconcile in BEIDE Richtungen, aber nur fuer Status, die das SYSTEM gesetzt hat (status_source='system'):
--       Bedingung jetzt wahr -> n.a. kippt auf open; Bedingung nicht mehr wahr (Merkmal zurueckgenommen, Register
--       geaendert) -> open kippt auf n.a.; fan_out-Tasks ohne Stub mehr -> n.a. Vom NUTZER gesetzte Status
--       (status_source='user': done, "trifft nicht zu", wieder offen) fasst der Reconcile nie an. Der Auto-Complete-
--       Trigger kann den Fall dabei schliessen (letzte offene Task n.a.) -> fn_set_case meldet case_status.
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
        status     = CASE WHEN case_tasks.status_source = 'system' THEN excluded.status
                          ELSE case_tasks.status END,
        updated_at = now();

    -- Vom System offene Template-Tasks, die der Soll-Satz nicht mehr liefert (fan_out-Stub geloescht, Bedingung
    -- eines fan_out-Templates entfallen) -> n.a.; retired Templates bleiben unberuehrt (Katalog-Pflege, kein Fakt).
    UPDATE estate.case_tasks ct
       SET status = 'not_applicable'
     WHERE ct.case_id = p_case_id
       AND ct.status_source = 'system' AND ct.status = 'open' AND ct.template_key IS NOT NULL
       AND EXISTS (SELECT 1 FROM estate.task_templates t WHERE t.template_key = ct.template_key AND NOT t.retired)
       AND NOT EXISTS (SELECT 1
                         FROM estate.fn_case_template_rows(v_type, v_subject, v_flags, v_event, v_know, v_bl) r
                        WHERE r.template_key = ct.template_key AND r.subject_ref = ct.subject_ref);
END;
$$;
