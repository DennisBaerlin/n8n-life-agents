-- ============================================================
-- career.fn_handle_job_feedback (CALLBACK HANDLER)
--   Callback-Handler hinter der Registry core.callback_handlers (prefix 'job' -> diese fn). Der Orchestrator
--   dispatcht 👍/👎-Taps an einer Job-Treffer-Karte ueber core.fn_dispatch_callback hierher
--   (Eingabe p->>'data' = 'job:up:<id>' / 'job:down:<id>', p->>'chat_id' = Sender-Chat).
--
--   Rollenmodell: SECURITY INVOKER + SET search_path=pg_catalog (CVE-2018-1058). Der Orchestrator ruft den
--   Dispatcher unter dem RW/Host-Credential (N8N_DB_USER, EXECUTE+UPDATE auf career.*), daher laeuft das UPDATE.
--   Eine enge RO-Rolle koennte die fn aufrufen, das UPDATE schlaegt dort aber strukturell fehl (kein Schreibrecht).
--
--   Eigentuemer-Check: nur eigene job_matches sind bewertbar. Der Sender wird aus dem Dispatch-chat_id via
--   agent.fn_resolve_sender aufgeloest (nie vom LLM), das UPDATE filtert WHERE person_id=<sender>. Ein Tap auf
--   eine fremde Stelle matcht keine Zeile -> 'job match not found' (gleiche Antwort wie nicht-existent, kein
--   Enumeration-Leak).
--   State-Machine: up -> status='interested', down -> status='dismissed'; Re-Tap idempotent, Flip erlaubt
--   (👍 dann 👎 -> dismissed); feedback_at=now() immer (Attribution "zuletzt bewertete Stelle" fuer den
--   Freitext-Grund-Loop des Advisors).
--   Rueckgabe: {ok:true, toast}. ok:false-reasons: 'unknown job feedback action "<a>"', 'invalid job id "<x>"',
--   'unresolved sender' (chat_id fehlt/nicht numerisch/unaufloesbar, kein Write), 'job match not found';
--   die beiden letzten mit toast. Raised nie (der Dispatcher faengt sonst keinen Owner-Alert ab). Der
--   Orchestrator rendert nur den toast (answerCallbackQuery); die optionale Freitext-Grund-Einladung steht auf
--   der Treffer-Karte (cron.score_jobs), nicht in dieser Rueckgabe.
--   Toasts aus dem Textkatalog (career.toast.*, core.toast.*) in der Sprache des Tippenden (agent.fn_person_lang:
--   Person -> Owner -> en).
--   Tests: tests/db/career/test_fn_handle_job_feedback.sql
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
    v_chat   bigint;   -- Sender-chat_id (RAISE-frei gecastet; der Dispatch reicht p->>'chat_id' durch)
    v_sender text;     -- aufgeloeste Sender-Person (Eigentuemer-Check)
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

    -- Eigentuemer-Check: Sender aus dem Dispatch-Payload-chat_id (nie vom LLM). chat_id RAISE-frei casten
    -- (nicht-numerisch/leer -> NULL -> unaufloesbar -> {ok:false}, kein RAISE -> kein Owner-Alert).
    -- Unaufloesbarer/fehlender Sender -> kein Write.
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

    -- WHERE person_id = v_sender: ein Tap auf eine fremde Stelle matcht keine Zeile -> NOT FOUND (deckt fremd
    -- und nicht-existent ab, kein Enumeration-Leak).
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
