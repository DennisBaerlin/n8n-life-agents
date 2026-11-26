-- ============================================================
-- core.fn_llm_probe_due (ATOMIC WRITE) + core.fn_llm_probe_result (ATOMIC WRITE) — Nachschau waehrend einer KI-Pause
--   Halb-offener Schutzschalter (Fowler CircuitBreaker): echte Nachrichten sind ohnehin Proben (eine abgelehnte 400 kostet
--   nichts); dazu schaut core.sub_llm_probe nach Plan nach, weil der Owner das Limit erhoehen kann, ohne dass jemand
--   schreibt. Plan (naechste Nachschau nach einer gescheiterten): Stoerung 2 -> 5 -> 10 Min; ohne Owner-Wahl 10 -> 30 ->
--   60 Min; raise alle 10 Min; wait genau resume_at + 1 Min, danach alle 10 Min. Erste Nachschau setzt fn_llm_incident_note.
--
--   fn_llm_probe_due(p {trigger? ('button' = sofort, ohne Plan und Sperre), at? (Testzeit)}): beansprucht den offenen Vorfall,
--     wenn next_probe_at erreicht ist und keine Nachschau laeuft (probe_lock_until, 2 Min). Raeumt gemerkte Nachrichten von Vorfaellen weg, die vor > 7 Tagen endeten.
--     Rueckgabe {ok:true, due, incident_id?, kind?, opened_at?} (opened_at: ein Erfolg des Gateways danach zaehlt
--     ohne eigene Probe, core.sub_llm_probe).
--   fn_llm_probe_result(p {incident_id, ok, trigger 'cron'|'button', at?}): ok -> Vorfall 'recovered' und Nachrichten:
--     je Person mit gemerkten Nachrichten „wieder da“ + Zitat (eine) bzw. Anzahl + letzte (mehrere) mit [Jetzt beantworten]
--     [Nicht mehr noetig]; Sprachnachrichten nur als Satz (kein Nachspielen, ihre Zeilen fallen weg); der Owner bekommt die
--     Entwarnung bei spend_limit/credit_empty/auth immer, bei Stoerung nur mit eigener gemerkter Nachricht (Owner-Entscheidung).
--     Nicht ok -> naechste Nachschau nach Plan; trigger button -> Satz „noch gesperrt“ + [Noch einmal nachschauen] an den Owner.
--     Rueckgabe {ok:true, recovered, messages:[{chat_id, text, buttons}]}; unbekannter oder beendeter Vorfall -> messages [].
--   Tests: tests/db/core/test_fn_llm_probe_due.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_llm_probe_due(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_at  timestamptz := COALESCE((p->>'at')::timestamptz, now());
    v_id  bigint;
    v_kind text;
    v_opened timestamptz;
BEGIN
    DELETE FROM agent.llm_held_messages h USING core.llm_incidents i
     WHERE h.incident_id = i.id AND i.closed_at < v_at - interval '7 days';
    -- Knopf (trigger button): ohne Plan und ohne Sperre, sonst kaeme nach dem Toast nichts, solange eine geplante Nachschau laeuft.
    UPDATE core.llm_incidents SET probe_lock_until = v_at + interval '2 minutes'
     WHERE closed_at IS NULL
       AND (p->>'trigger' = 'button' OR (next_probe_at <= v_at AND (probe_lock_until IS NULL OR probe_lock_until <= v_at)))
    RETURNING id, kind, opened_at INTO v_id, v_kind, v_opened;
    RETURN jsonb_build_object('ok', true, 'due', v_id IS NOT NULL, 'incident_id', v_id, 'kind', v_kind, 'opened_at', v_opened);
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_llm_probe_result(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_at     timestamptz := COALESCE((p->>'at')::timestamptz, now());
    v_inc    core.llm_incidents%ROWTYPE;
    v_step   int;
    v_next   timestamptz;
    v_owner  bigint := agent.fn_person_chat_id(agent.fn_owner_person_id());
    v_msgs   jsonb := '[]'::jsonb;
    v_lang   text;
    v_parts  text[];
    v_btn    jsonb;
    v_owner_done boolean := false;
    s        record;
BEGIN
    IF COALESCE(p->>'incident_id', '') !~ '^[0-9]{1,18}$' THEN
        RETURN jsonb_build_object('ok', true, 'recovered', false, 'messages', '[]'::jsonb);
    END IF;
    SELECT * INTO v_inc FROM core.llm_incidents WHERE id = (p->>'incident_id')::bigint AND closed_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', true, 'recovered', false, 'messages', '[]'::jsonb);
    END IF;

    IF COALESCE((p->>'ok')::boolean, false) IS NOT TRUE THEN
        v_step := v_inc.probe_step + 1;
        v_next := CASE
            WHEN v_inc.kind = 'outage' THEN v_at + CASE WHEN v_step = 1 THEN interval '5 minutes' ELSE interval '10 minutes' END
            WHEN v_inc.owner_choice = 'wait' AND v_inc.resume_at + interval '1 minute' > v_at THEN v_inc.resume_at + interval '1 minute'
            WHEN v_inc.owner_choice IN ('raise', 'wait') THEN v_at + interval '10 minutes'
            ELSE v_at + CASE WHEN v_step = 1 THEN interval '30 minutes' ELSE interval '60 minutes' END END;
        UPDATE core.llm_incidents SET probe_step = v_step, next_probe_at = v_next, probe_lock_until = NULL WHERE id = v_inc.id;
        IF p->>'trigger' = 'button' AND v_owner IS NOT NULL THEN
            v_lang := agent.fn_person_lang(NULL)->>'lang';
            v_msgs := jsonb_build_array(jsonb_build_object('chat_id', v_owner::text,
                'text', core.fn_ui_text('core.llm_pause.still_blocked', v_lang),
                'buttons', jsonb_build_array(jsonb_build_array(jsonb_build_object(
                    'text', core.fn_ui_text('core.llm_pause.btn_check_again', v_lang), 'data', 'llm:check:' || v_inc.id)))));
        END IF;
        RETURN jsonb_build_object('ok', true, 'recovered', false, 'messages', v_msgs);
    END IF;

    UPDATE core.llm_incidents SET closed_at = v_at, close_reason = 'recovered', probe_lock_until = NULL WHERE id = v_inc.id;

    -- je Person mit gemerkten Nachrichten dieses Vorfalls (ein ersetzter Vorfall hat seine Zeilen schon weitergegeben)
    FOR s IN
        SELECT h.chat_id, h.from_id,
               count(*) FILTER (WHERE h.kind <> 'voice') AS n,
               count(*) FILTER (WHERE h.kind = 'voice') AS n_voice,
               (array_agg(h.payload->'message' ORDER BY h.message_id DESC, h.update_id DESC) FILTER (WHERE h.kind <> 'voice'))[1] AS last_m,
               max(h.sent_at) FILTER (WHERE h.kind <> 'voice') AS last_at,
               max(h.sent_at) FILTER (WHERE h.kind = 'voice') AS voice_at
          FROM agent.llm_held_messages h
         WHERE h.incident_id = v_inc.id
         GROUP BY h.chat_id, h.from_id
         ORDER BY min(h.message_id)
    LOOP
        v_lang := agent.fn_person_lang(agent.fn_resolve_sender(s.from_id)->>'person_id')->>'lang';
        v_parts := ARRAY[core.fn_ui_text('core.llm_pause.back', v_lang)];
        v_btn := '[]'::jsonb;
        IF s.n > 0 THEN
            v_parts := v_parts || core.fn_ui_text(CASE WHEN s.n = 1 THEN 'core.llm_pause.back_held_one' ELSE 'core.llm_pause.back_held_many' END,
                v_lang, jsonb_build_object('count', s.n::text, 'when', core.fn_llm_when(s.last_at, v_lang),
                    'quote', (SELECT CASE WHEN length(q) > 80 THEN left(q, 80) || '…' ELSE q END
                                FROM (SELECT btrim(COALESCE(NULLIF(s.last_m->>'text', ''), NULLIF(s.last_m->>'caption', ''),
                                                            s.last_m->'document'->>'file_name', '📎')) AS q) x)));
            v_btn := jsonb_build_array(jsonb_build_array(
                jsonb_build_object('text', core.fn_ui_text('core.llm_pause.btn_replay', v_lang), 'data', 'llm:replay:' || v_inc.id),
                jsonb_build_object('text', core.fn_ui_text('core.llm_pause.btn_drop', v_lang), 'data', 'llm:drop:' || v_inc.id)));
        END IF;
        IF s.n_voice > 0 THEN
            v_parts := v_parts || core.fn_ui_text('core.llm_pause.back_held_voice', v_lang,
                jsonb_build_object('when', core.fn_llm_when(s.voice_at, v_lang)));
            DELETE FROM agent.llm_held_messages WHERE incident_id = v_inc.id AND chat_id = s.chat_id AND from_id = s.from_id AND kind = 'voice';
        END IF;
        v_msgs := v_msgs || jsonb_build_array(jsonb_build_object('chat_id', s.chat_id::text,
            'text', array_to_string(v_parts, E'\n\n'), 'buttons', v_btn));
        IF s.chat_id = v_owner THEN v_owner_done := true; END IF;
    END LOOP;

    IF v_inc.kind <> 'outage' AND NOT v_owner_done AND v_owner IS NOT NULL THEN
        v_msgs := v_msgs || jsonb_build_array(jsonb_build_object('chat_id', v_owner::text,
            'text', core.fn_ui_text('core.llm_pause.back', agent.fn_person_lang(NULL)->>'lang'), 'buttons', '[]'::jsonb));
    END IF;
    RETURN jsonb_build_object('ok', true, 'recovered', true, 'messages', v_msgs);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_llm_probe_due(jsonb) FROM public;
REVOKE ALL ON FUNCTION core.fn_llm_probe_result(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_llm_probe_due(JSONB) FROM context_ro;
        REVOKE ALL ON FUNCTION core.fn_llm_probe_result(JSONB) FROM context_ro;
    END IF;
END $$;
