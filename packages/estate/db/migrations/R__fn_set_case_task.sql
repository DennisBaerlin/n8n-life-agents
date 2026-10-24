-- ============================================================
-- estate.fn_set_case_task (ATOMIC WRITE — WS-3; das Tool fragt seit dem Security-Audit 2026-10 per Karte, owner_info)
--   Setzt den Status EINER Task (open|done|not_applicable). Das Tool laeuft als Probelauf VOR der Karte und nach
--   dem Tipp als Write (Owner-Entscheid "Karte nur bei Abhaken"); der est:-Callback ist selbst ein menschlicher
--   Tipp. adults_only-DB-Backstop (Kind -> {ok:false}). GUARD: die Task muss zu einem OFFENEN Fall
--   gehoeren (Tasks abgeschlossener/abgebrochener/superseded Faelle sind eingefroren). done -> done_at
--   materialisiert. Der Auto-Complete-Trigger kann den Fall danach auf 'completed' kippen -> der
--   Post-State liest den Fall-Status FRISCH (nach dem Trigger, in derselben Tx).
--   Wird von ZWEI Aufrufern genutzt: dem Tool (unter estate_rw) UND dem est:-Callback-Handler
--   (fn_handle_case_task_callback, unter dem Host-RW-Credential) — beide erreichen die core-Windows.
--   Eingabe jsonb: chat_id, case_task_id, status. RUECKGABE: {ok:true, case_task_id, status, case_id,
--     case_status, case_completed} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_case_task.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_case_task(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm      TEXT;
    v_id        BIGINT := NULLIF(p->>'case_task_id', '')::bigint;
    v_status    TEXT := lower(NULLIF(trim(COALESCE(p->>'status', '')), ''));
    v_case      BIGINT;
    v_cstatus   TEXT;
    v_new_cstat TEXT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'Write rejected (' || v_perm || '): only adult household members (owner/partner) may update an event task.');
    END IF;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case_task_id is required.');
    END IF;
    IF v_status IS NULL OR v_status NOT IN ('open', 'done', 'not_applicable') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'status must be open, done or not_applicable.');
    END IF;
    SELECT ct.case_id, c.status INTO v_case, v_cstatus
      FROM estate.case_tasks ct JOIN estate.cases c ON c.id = ct.case_id
     WHERE ct.id = v_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'task not found.');
    END IF;
    IF v_cstatus <> 'open' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'the case for this task is not open (status ' || v_cstatus || ') — cannot change its tasks.');
    END IF;

    UPDATE estate.case_tasks
       SET status  = v_status,
           done_at = CASE WHEN v_status = 'done' THEN now() ELSE NULL END
     WHERE id = v_id;

    SELECT status INTO v_new_cstat FROM estate.cases WHERE id = v_case;   -- nach dem Auto-Complete-Trigger

    RETURN jsonb_build_object('ok', true, 'case_task_id', v_id, 'status', v_status,
        'case_id', v_case, 'case_status', v_new_cstat, 'case_completed', v_new_cstat = 'completed');
END;
$$;
