-- ============================================================
-- core.fn_handle_llm_cb (ATOMIC WRITE) — Knoepfe der KI-Pause (Callback-Registry-Prefix 'llm', member_permeable)
--   data = llm:<aktion>:<incident_id>; der Dispatcher core.fn_dispatch_callback hat den Absender schon aufgeloest.
--   Nur Privatchat. Aktionen:
--     guide  (Owner): owner_choice raise, Nachschau spaetestens in 10 Min; reply = Anleitung (Limit bzw. Guthaben) mit
--            [Erledigt – jetzt nachschauen]; edit keep_text (Knoepfe der Karte weg). Schluessel/Stoerung -> Toast.
--     wait   (Owner, nur spend_limit mit Datum): owner_choice wait, Nachschau resume_at + 1 Min; reply mit [Limit erhoehen].
--     check  (Owner): Nachschau sofort faellig; route 'llm_probe' (der Orchestrator ruft core.sub_llm_probe, trigger button).
--     replay (jede Person, nur eigene gemerkte Nachrichten): Texte und Dateien in Reihenfolge zu einem Update zusammengefuehrt
--            (agent.fn_merge_ingress_updates), alle eigenen Zeilen geloescht (Sprachnachrichten werden nicht nachgespielt);
--            route 'replay' + update -> der Orchestrator speist es in 'Trigger normalize' wie eine neue Nachricht.
--     drop   (jede Person): eigene gemerkte Nachrichten loeschen.
--   Beendeter oder unbekannter Vorfall (guide/wait/check) -> Toast; unbekannte Aktion/Gruppe -> ok:false. Nie RAISE.
--   Generische Registry-Felder: toast, edit {keep_text}, reply {text, buttons} (Nachricht an den Tippenden), route + update.
--   Rueckgabe: {ok, toast?, reply?, edit?, route?, update?, incident_id?} | {ok:false, reason, toast}
--   Tests: tests/db/core/test_fn_handle_llm_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_llm_cb(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_parts  text[] := string_to_array(COALESCE(p->>'data', ''), ':');
    v_action text;
    v_chat   bigint;
    v_sender jsonb;
    v_lang   text;
    v_inc    core.llm_incidents%ROWTYPE;
    v_upd    jsonb;
BEGIN
    v_action := v_parts[2];
    IF COALESCE(p->>'chat_id', '') ~ '^[0-9]{1,18}$' THEN
        v_chat := (p->>'chat_id')::bigint;
        v_sender := agent.fn_resolve_sender(v_chat);
    END IF;
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';
    IF v_chat IS NULL OR p->>'chat_type' IS DISTINCT FROM 'private' OR v_action IS NULL
       OR v_action NOT IN ('guide', 'wait', 'check', 'replay', 'drop') OR COALESCE(v_parts[3], '') !~ '^[0-9]{1,18}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid', 'toast', core.fn_ui_text('core.orch.toast_action_unavailable', v_lang));
    END IF;

    IF v_action = 'replay' THEN
        SELECT agent.fn_merge_ingress_updates(jsonb_agg(h.payload ORDER BY h.message_id, h.update_id)) INTO v_upd
          FROM agent.llm_held_messages h WHERE h.chat_id = v_chat AND h.from_id = v_chat AND h.kind <> 'voice';
        DELETE FROM agent.llm_held_messages WHERE chat_id = v_chat AND from_id = v_chat;
        IF v_upd IS NULL THEN
            RETURN jsonb_build_object('ok', true, 'toast', core.fn_ui_text('core.llm_pause.toast_nothing', v_lang), 'edit', jsonb_build_object('keep_text', true));
        END IF;
        RETURN jsonb_build_object('ok', true, 'route', 'replay', 'update', v_upd,
            'toast', core.fn_ui_text('core.llm_pause.toast_replay', v_lang), 'edit', jsonb_build_object('keep_text', true));
    END IF;
    IF v_action = 'drop' THEN
        DELETE FROM agent.llm_held_messages WHERE chat_id = v_chat AND from_id = v_chat;
        RETURN jsonb_build_object('ok', true, 'toast', core.fn_ui_text('core.llm_pause.toast_dropped', v_lang), 'edit', jsonb_build_object('keep_text', true));
    END IF;

    -- guide / wait / check: nur der Owner
    IF v_sender->>'role' IS DISTINCT FROM 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only', 'toast', core.fn_ui_text('core.toast.owner_only', v_lang));
    END IF;
    SELECT * INTO v_inc FROM core.llm_incidents WHERE id = v_parts[3]::bigint AND closed_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'over', 'toast', core.fn_ui_text('core.llm_pause.toast_over', v_lang),
            'edit', jsonb_build_object('keep_text', true));
    END IF;

    IF v_action = 'guide' THEN
        IF v_inc.kind NOT IN ('spend_limit', 'credit_empty') THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'no_guide', 'toast', core.fn_ui_text('core.orch.toast_action_unavailable', v_lang));
        END IF;
        UPDATE core.llm_incidents SET owner_choice = 'raise', next_probe_at = LEAST(next_probe_at, now() + interval '10 minutes')
         WHERE id = v_inc.id;
        RETURN jsonb_build_object('ok', true, 'toast', '', 'edit', jsonb_build_object('keep_text', true),
            'reply', jsonb_build_object(
                'text', core.fn_ui_text(CASE v_inc.kind WHEN 'spend_limit' THEN 'core.llm_pause.guide_raise' ELSE 'core.llm_pause.guide_topup' END, v_lang),
                'buttons', jsonb_build_array(jsonb_build_array(jsonb_build_object(
                    'text', core.fn_ui_text('core.llm_pause.btn_check', v_lang), 'data', 'llm:check:' || v_inc.id)))));
    END IF;
    IF v_action = 'wait' THEN
        IF v_inc.kind <> 'spend_limit' OR v_inc.resume_at IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'no_date', 'toast', core.fn_ui_text('core.orch.toast_action_unavailable', v_lang));
        END IF;
        UPDATE core.llm_incidents SET owner_choice = 'wait', next_probe_at = v_inc.resume_at + interval '1 minute' WHERE id = v_inc.id;
        RETURN jsonb_build_object('ok', true, 'toast', '', 'edit', jsonb_build_object('keep_text', true),
            'reply', jsonb_build_object(
                'text', core.fn_ui_text('core.llm_pause.wait_ok', v_lang, jsonb_build_object(
                    'date', core.fn_ui_date(v_inc.resume_at::date), 'time', to_char(v_inc.resume_at, 'HH24:MI'))),
                'buttons', jsonb_build_array(jsonb_build_array(jsonb_build_object(
                    'text', core.fn_ui_text('core.llm_pause.btn_raise', v_lang), 'data', 'llm:guide:' || v_inc.id)))));
    END IF;
    -- check
    UPDATE core.llm_incidents SET next_probe_at = now() WHERE id = v_inc.id;
    RETURN jsonb_build_object('ok', true, 'route', 'llm_probe', 'incident_id', v_inc.id,
        'toast', core.fn_ui_text('core.llm_pause.toast_checking', v_lang));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_handle_llm_cb(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_handle_llm_cb(JSONB) FROM context_ro;
    END IF;
END $$;
