-- ============================================================
-- career.fn_handle_job_feedback (WS-2 — Callback-Handler des job:-Prefixes)
--   Generischer Callback-Handler hinter der Phase-0-Registry core.callback_handlers (prefix 'job' ->
--   diese fn). Der Orchestrator dispatcht 👍/👎-Taps an einer Job-Treffer-Karte ueber core.fn_dispatch_
--   callback hierher (callback_data 'job:up:<id>' / 'job:down:<id>'). KEIN Orchestrator-Edit (additiv auf
--   der toten 'extra'-Ausgabe — Phase 0 WS-0c CB).
--
--   ROLLENMODELL (Praezedenz fn_dispatch_callback / fn_advisor_review_evaluate): SECURITY INVOKER +
--   SET search_path=pg_catalog (CVE-2018-1058). Der Orchestrator ruft den Dispatcher unter dem RW/Host-
--   Credential (N8N_DB_USER, EXECUTE+UPDATE auf career.*) -> das UPDATE laeuft. Eine enge RO-Rolle koennte
--   die fn zwar aufrufen, das UPDATE schlaegt dort aber strukturell fehl (kein Schreibrecht) -> safe.
--
--   EIGENTUEMER-CHECK (P2a): nur EIGENE job_matches sind bewertbar — der Sender wird aus dem Dispatch-chat_id
--   via agent.fn_resolve_sender aufgeloest (NIE vom LLM), der UPDATE filtert WHERE person_id=<sender>. Ein Tap auf
--   eine fremde Stelle matcht keine Zeile -> NOT FOUND (gleiche Antwort wie nicht-existent -> kein Enumeration-Leak).
--   STATE-MACHINE: up -> status='interested', down -> status='dismissed'; Re-Tap idempotent (gleicher
--   Status), Flip erlaubt (👍 dann 👎 -> dismissed); feedback_at=now() IMMER (Attribution "zuletzt
--   bewertete Stelle" fuer den Freitext-Grund-Loop des Advisors). NIE RAISE (der Dispatcher faengt sonst
--   keinen Owner-Alert ab): unbekannte Aktion/id/nicht gefunden -> {ok:false, reason} (+ toast wo sinnvoll).
--   RUECKGABE: {ok, toast} — der Orchestrator rendert NUR den toast (answerCallbackQuery); die optionale
--   Freitext-Grund-Einladung steht auf der Treffer-KARTE (cron.score_jobs), nicht in dieser Rueckgabe.
--   Toasts aus dem Textkatalog (career.toast.*, core.toast.*) in der Sprache des Tippenden (agent.fn_person_lang:
--   Person -> Owner -> en), Muster agent.fn_set_person_language.
--   Tests: tests/db/career/test_fn_handle_job_feedback.sql
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_handle_job_feedback.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_handle_job_feedback(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_action text := split_part(v_data, ':', 2);   -- 'job':<action>:<id>
    v_id_txt text := split_part(v_data, ':', 3);
    v_id     bigint;
    v_chat   bigint;   -- P2a: Sender-chat_id (RAISE-frei gecastet; der Dispatch reicht p->>'chat_id' durch)
    v_sender text;     -- P2a: aufgeloeste Sender-Person (Eigentuemer-Check)
    v_status text;
BEGIN
    IF v_action NOT IN ('up', 'down') THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('unknown job feedback action "%s"', v_action));
    END IF;
    BEGIN
        v_id := v_id_txt::bigint;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('invalid job id "%s"', v_id_txt));
    END;

    -- P2a EIGENTUEMER-CHECK: nur EIGENE job_matches sind bewertbar. Sender aus dem Dispatch-Payload-chat_id
    -- (NIE vom LLM). chat_id RAISE-frei casten (nicht-numerisch/leer -> NULL -> unaufloesbar -> {ok:false},
    -- kein RAISE -> kein Owner-Alert). Unaufloesbarer/fehlender Sender -> kein Write.
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := NULLIF(agent.fn_resolve_sender(v_chat)->>'person_id', '');
    IF v_sender IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unresolved sender',
            'toast', core.fn_ui_text('core.toast.unresolved_sender', agent.fn_person_lang(NULL)->>'lang'));
    END IF;

    v_status := CASE WHEN v_action = 'up' THEN 'interested' ELSE 'dismissed' END;

    -- WHERE person_id = v_sender: ein Tap auf eine FREMDE Stelle matcht keine Zeile -> NOT FOUND (deckt fremd
    -- UND nicht-existent ab -> kein Enumeration-Leak, gleiche Antwort).
    UPDATE career.job_matches
       SET status = v_status, feedback_at = now()
     WHERE id = v_id AND person_id = v_sender;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'job match not found',
            'toast', core.fn_ui_text('career.toast.job_not_found', agent.fn_person_lang(v_sender)->>'lang'));
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'toast', core.fn_ui_text(CASE WHEN v_action = 'up' THEN 'career.toast.job_up' ELSE 'career.toast.job_down' END,
                                 agent.fn_person_lang(v_sender)->>'lang')
    );
END;
$$;
