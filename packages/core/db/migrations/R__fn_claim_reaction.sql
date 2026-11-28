-- ============================================================
-- agent.fn_claim_reaction (Emoji-Reaktion an der Nutzer-Nachricht)
--   Die eine Entscheidung, ob der Bot eine Reaktion an die Nachricht setzt (kein LLM, das LLM liefert nur das Rohsignal
--   der Router-Zeile). Der Orchestrator ruft sie an zwei Stellen: event 'seen' beim Eingang eines Fotos/Dokuments,
--   event 'reply' nach der Antwort-Komposition (Relay compose) zusammen mit dem Sticker. Der Gateway setzt das Emoji
--   (setMessageReaction; je Nachricht hoechstens eine Reaktion, eine neue ersetzt die alte).
--   Zero-Trust: re-resolvt den Absender selbst aus p->>'chat_id' (wie agent.fn_claim_persona_sticker).
--   Auswahl (hoechstens eine, Prioritaet):
--     seen   👀  event 'seen' (Lebenszeichen, ohne Obergrenze)
--     done   👌  Karte dieses Laufs endgueltig bestaetigt (agent.hitl_pending.approved, opened_at >= run_started_at)
--                + reply_ok + Signal FRAME + kein Sticker in diesem Lauf + kein Folgetext (has_text false, auch eine Antwort mit Knoepfen zaehlt als Text; sonst bleibt 👀)
--     answer     Stimmung statt Text: kein Werkzeug, react_only, kein Text (Router-Zeile genau 'REACT <MOOD>')
--   Keine Stimmung neben einer Antwort: eine Reaktion an einer Nachricht, die die lange Antwort schon aus dem Bild geschoben
--   hat, zeigt Telegram am Handy als Reaktions-Zaehler.
--   Stimmungen: LOVE ❤ · CHEER 🎉 · RELIEF 🙏 · FUN 😁 (unbekannt -> keine). Jede Stimmung verlangt reply_ok und nie
--     Signal NOFRAME (ernster Moment); lief ein Werkzeug ohne gueltiges Signal, gilt das als NOFRAME. Eine Nachricht
--     mit 👀 bekommt keine Stimmung (👀 bleibt stehen, nur 👌 ersetzt es).
--   Schreibt die Zeile in agent.reaction_log (ON CONFLICT DO NOTHING: dieselbe Art an derselben Nachricht nie zweimal
--     -> dann keine Reaktion) und loescht Zeilen der Person, die aelter als 30 Tage sind. Aus-Schalter
--     persona.reactions_enabled.
--   Eingabe p: {chat_id, message_id, event:'seen'|'reply', signal, mood, react_only, has_text, tool_called, reply_ok,
--       run_started_at (timestamptz), sticker}
--   Rueckgabe: {ok:true, emoji:text|null, kind:'seen'|'done'|'answer'|null}  (nie RAISE -> ein Fehler kostet nur
--     die Reaktion)
--   Tests: tests/db/core/test_fn_claim_reaction.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_claim_reaction(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_none    constant jsonb := jsonb_build_object('ok', true, 'emoji', NULL, 'kind', NULL);
    v_chat    bigint;
    v_msg     bigint;
    v_since   timestamptz;
    v_sender  jsonb;
    v_pid     text;
    v_signal  text := upper(btrim(COALESCE(p->>'signal', '')));
    v_tool    boolean;
    v_ok      boolean;
    v_emoji   text;
    v_kind    text;
    v_id      bigint;
BEGIN
    IF COALESCE(core.fn_config_get('core', 'persona', 'reactions_enabled'), 'true') <> 'true' THEN
        RETURN v_none;
    END IF;
    BEGIN
        v_chat  := NULLIF(p->>'chat_id', '')::bigint;
        v_msg   := NULLIF(p->>'message_id', '')::bigint;
        v_since := NULLIF(p->>'run_started_at', '')::timestamptz;
        v_tool  := COALESCE(NULLIF(p->>'tool_called', '')::boolean, false);
        v_ok    := COALESCE(NULLIF(p->>'reply_ok', '')::boolean, false);
    EXCEPTION WHEN OTHERS THEN
        RETURN v_none;
    END;
    IF v_chat IS NULL OR v_msg IS NULL THEN
        RETURN v_none;
    END IF;
    v_sender := agent.fn_resolve_sender(v_chat);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN v_none;
    END IF;
    v_pid := v_sender->>'person_id';

    IF p->>'event' = 'seen' THEN
        v_kind := 'seen';  v_emoji := '👀';
    ELSIF p->>'event' IS DISTINCT FROM 'reply' THEN
        RETURN v_none;
    ELSIF v_signal = 'FRAME' AND v_ok AND v_since IS NOT NULL AND COALESCE(p->>'sticker', '') = ''
          AND NOT COALESCE(NULLIF(p->>'has_text', '')::boolean, false) AND EXISTS (
            SELECT 1 FROM agent.hitl_pending h
             WHERE h.chat_id = v_chat AND h.approved IS TRUE AND h.opened_at >= v_since) THEN
        v_kind := 'done';  v_emoji := '👌';
    ELSE
        v_emoji := CASE upper(btrim(COALESCE(p->>'mood', '')))
                     WHEN 'LOVE' THEN '❤' WHEN 'CHEER' THEN '🎉' WHEN 'RELIEF' THEN '🙏' WHEN 'FUN' THEN '😁' END;
        IF v_emoji IS NULL OR NOT v_ok OR v_signal = 'NOFRAME' OR (v_tool AND v_signal <> 'FRAME') THEN
            RETURN v_none;
        END IF;
        -- 👀 bleibt stehen, nur 👌 ersetzt es (Telegram: eine Reaktion je Bot und Nachricht).
        IF EXISTS (SELECT 1 FROM agent.reaction_log r
                    WHERE r.chat_id = v_chat AND r.message_id = v_msg AND r.kind = 'seen') THEN
            RETURN v_none;
        END IF;
        IF NOT v_tool AND COALESCE((p->>'react_only')::boolean, false) AND NOT COALESCE(NULLIF(p->>'has_text', '')::boolean, false) THEN
            v_kind := 'answer';
        ELSE
            RETURN v_none;
        END IF;
    END IF;

    DELETE FROM agent.reaction_log r WHERE r.person_id = v_pid AND r.created_at < now() - interval '30 days';
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji)
    VALUES (v_pid, v_chat, v_msg, v_kind, v_emoji)
    ON CONFLICT (chat_id, message_id, kind) DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RETURN v_none;
    END IF;

    RETURN jsonb_build_object('ok', true, 'emoji', v_emoji, 'kind', v_kind);
EXCEPTION WHEN OTHERS THEN
    RETURN v_none;
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_claim_reaction(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_claim_reaction(JSONB) FROM context_ro;
    END IF;
END $$;
