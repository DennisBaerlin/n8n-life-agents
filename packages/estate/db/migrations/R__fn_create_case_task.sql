-- ============================================================
-- estate.fn_create_case_task (ATOMIC WRITE — WS-3, Fortschritts-Flag-Klasse: KEIN HITL am Tool)
--   Fuegt eine MANUELLE Task (template_key NULL) zu einem OFFENEN Fall hinzu — fuer haushaltsspezifische
--   Schritte, die kein Template abdeckt. Fortschritts-Flag-Klasse (kein Gate); adults_only-DB-Backstop.
--   Manuelle Tasks (template_key NULL, subject_ref '') sind vom additiven Reconcile (fn_set_case) nie
--   beruehrt — sie ueberleben Fristen-Recomputes. GUARD: nur OFFENE Faelle. phase Default first_week.
--   Eingabe jsonb: chat_id, case_id, title, phase (optional), detail (optional), due_date (optional; YYYY-MM-DD oder
--     relativ, core.fn_resolve_input_dates). status_source='user' (vom Nutzer angelegt).
--   RUECKGABE: {ok:true, case_task_id, case_id, due_date (aufgeloest)} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_create_case_task.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_case_task(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm    TEXT;
    v_case    BIGINT := NULLIF(p->>'case_id', '')::bigint;
    v_cstatus TEXT;
    v_title   TEXT := NULLIF(trim(COALESCE(p->>'title', '')), '');
    v_phase   TEXT := lower(NULLIF(trim(COALESCE(p->>'phase', '')), ''));
    v_due     DATE;
    v_id      BIGINT;
    v_dates   JSONB;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'Write rejected (' || v_perm || '): only adult household members (owner/partner) may add an event task.');
    END IF;
    IF v_case IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case_id is required.');
    END IF;
    IF v_title IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'title is required (non-empty).');
    END IF;
    v_phase := COALESCE(v_phase, 'first_week');
    IF v_phase NOT IN ('immediate', 'first_week', 'first_month', 'later') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'phase must be immediate, first_week, first_month or later.');
    END IF;
    SELECT status INTO v_cstatus FROM estate.cases WHERE id = v_case;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case not found.');
    END IF;
    IF v_cstatus <> 'open' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'case ' || v_case || ' is not open (status ' || v_cstatus || ') — cannot add tasks.');
    END IF;
    -- WP3: relative Faelligkeit ("in 3 days", "next friday") rechnet die DB (kein HITL -> genau ein Aufloesungszeitpunkt).
    v_dates := core.fn_resolve_input_dates(p, ARRAY['due_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    v_due := NULLIF(v_dates->'resolved'->>'due_date', '')::date;

    INSERT INTO estate.case_tasks (case_id, template_key, subject_ref, phase, title, detail, due_date, hardness, status, status_source)
    VALUES (v_case, NULL, '', v_phase, v_title, NULLIF(trim(COALESCE(p->>'detail', '')), ''), v_due, 'recommended', 'open', 'user')
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'case_task_id', v_id, 'case_id', v_case, 'due_date', v_due);
END;
$$;
