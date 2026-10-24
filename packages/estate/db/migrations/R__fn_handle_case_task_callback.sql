-- ============================================================
-- estate.fn_handle_case_task_callback (WS-3 — Callback-Handler des est:-Prefixes)
--   Hinter der Phase-0-Registry core.callback_handlers (prefix 'est' -> diese fn). Der Owner tippt an
--   der Erinnerungs-Karte (cron_remind_case_tasks) einen Button 'est:done:<task_id>' / 'est:skip:<task_id>'
--   -> der Orchestrator dispatcht ueber core.fn_dispatch_callback hierher (KEIN Orchestrator-Edit,
--   additiv auf der 'extra'-Ausgabe). Muster career.fn_handle_job_feedback.
--   ROLLENMODELL: SECURITY INVOKER + SET search_path=pg_catalog (CVE-2018-1058). Der Dispatcher laeuft
--   unter dem Host-RW-Credential (N8N_DB_USER) -> agent.fn_resolve_sender + estate.fn_set_case_task sind
--   erreichbar (KEIN D10-Problem wie in den estate_rw-Write-fns).
--   MEMBER-PERMEABEL (core.callback_handlers.member_permeable=true; der Dispatcher core.fn_dispatch_callback
--   enforced es fail-closed + routet ein aufgeloestes Nicht-Owner-Mitglied hierher): der Sender MUSS ein
--   aufgeloestes Haushaltsmitglied sein (sonst {ok:false, toast}). Die eigentliche adults_only-Pruefung + der
--   "Fall offen?"-Guard + der Auto-Complete liegen in estate.fn_set_case_task (EINE Write-fn, kein
--   Duplikat). NIE RAISE (der Dispatcher faengt sonst keinen Owner-Alert ab): jeder Fehler -> {ok:false,
--   reason, toast}. RUECKGABE: {ok, toast[, case_completed]} — der Orchestrator rendert nur den toast.
--   Toasts aus dem Textkatalog (estate.toast.*, core.toast.*) in der Sprache des Tippenden (agent.fn_person_lang:
--   Person -> Owner -> en; der Sender wird dafuer VOR jeder Pruefung aufgeloest), Muster agent.fn_set_person_language.
--   Tests: tests/db/estate/test_fn_handle_case_task_callback.sql
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_handle_case_task_callback.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_handle_case_task_callback(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_data   TEXT := COALESCE(p->>'data', '');
    v_action TEXT := split_part(v_data, ':', 2);   -- 'est':<action>:<id>
    v_id_txt TEXT := split_part(v_data, ':', 3);
    v_id     BIGINT;
    v_chat   BIGINT;
    v_sender TEXT;
    v_status TEXT;
    v_res    JSONB;
    v_lang   TEXT;
BEGIN
    -- Sender ZUERST aufloesen: jeder Toast kommt in der Sprache des Tippenden (Textkatalog §3.11; unaufgeloest ->
    -- Owner-Sprache, agent.fn_person_lang). chat_id RAISE-frei casten.
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := NULLIF(agent.fn_resolve_sender(v_chat)->>'person_id', '');
    v_lang := agent.fn_person_lang(v_sender)->>'lang';

    IF v_action NOT IN ('done', 'skip') THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('unknown est action "%s"', v_action),
            'toast', core.fn_ui_text('core.toast.unknown_action', v_lang));
    END IF;
    BEGIN
        v_id := v_id_txt::bigint;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('invalid task id "%s"', v_id_txt),
            'toast', core.fn_ui_text('estate.toast.invalid_task', v_lang));
    END;

    -- Member-permeabel: der Sender muss ein aufgeloestes Haushaltsmitglied sein (Owner ODER Partner/Kind);
    -- der Dispatcher hat member_permeable schon geprueft.
    IF v_sender IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unresolved sender',
            'toast', core.fn_ui_text('core.toast.unresolved_sender', v_lang));
    END IF;

    v_status := CASE v_action WHEN 'done' THEN 'done' ELSE 'not_applicable' END;

    -- Delegiert an die EINE Write-fn (adults_only-Backstop + "Fall offen?" + Auto-Complete). Wrap: ein
    -- unerwarteter Fehler darf keinen Owner-Alert ausloesen (der Dispatcher faengt nichts ab).
    BEGIN
        v_res := estate.fn_set_case_task(jsonb_build_object(
            'chat_id', p->>'chat_id', 'case_task_id', v_id, 'status', v_status));
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'set failed',
            'toast', core.fn_ui_text('core.toast.save_failed', v_lang));
    END;

    IF COALESCE((v_res->>'ok')::boolean, false) THEN
        RETURN jsonb_build_object('ok', true,
            'toast', core.fn_ui_text(CASE v_action WHEN 'done' THEN 'estate.toast.task_done'
                                                    ELSE 'estate.toast.task_not_applicable' END, v_lang),
            'case_completed', COALESCE((v_res->>'case_completed')::boolean, false));
    ELSE
        RETURN jsonb_build_object('ok', false, 'reason', v_res->>'reason',
            'toast', core.fn_ui_text(CASE
                WHEN v_res->>'reason' LIKE 'Write rejected%' THEN 'estate.toast.adults_only'
                WHEN v_res->>'reason' LIKE 'the case%'       THEN 'estate.toast.case_closed'
                ELSE 'estate.toast.task_not_found' END, v_lang));
    END IF;
END;
$$;
