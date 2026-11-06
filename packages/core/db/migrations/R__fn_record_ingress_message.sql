-- ============================================================
-- fn_record_ingress_message (Telegram-Eingangs-Buendelung, Schritt 1)
--   Der Orchestrator-Eingang ruft sie fuer jedes message-Update: legt die Zeile (update_id, chat, Absender,
--   message_id, kind, exec_id) an und sagt dem Eingang, wie es weitergeht (action):
--     text/file -> wait    (Payload = rohes Update; nach dem kurzen Warten entscheidet fn_claim_ingress_burst)
--     solo      -> process (sofort, ohne Payload, gleich als selbst-beansprucht angelegt -> nie gebuendelt)
--     dasselbe update_id erneut (Telegram-Webhook-Retry) -> drop (keine neue Zeile)
--   kind: text (message.text, das nach fuehrendem Leerraum nicht mit '/' beginnt), file (message.photo |
--   message.document), solo (alles andere: Befehl, Sprache, Audio, Video ...).
--   Raeumt vorher Zeilen > 2 min weg (Aufraeumen bei jedem Eingang, kein Cron).
--   Fehlende exec_id = Bau-Fehler des Aufrufers -> RAISE (der Eingang ist fail-open, der Lauf geht weiter).
--   p: { update, exec_id }
--   RUECKGABE: {ok:true, action: wait|process|drop, kind, duplicate} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_ingress_buffer.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_record_ingress_message(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_exec text  := NULLIF(trim(p->>'exec_id'), '');
    v_u    jsonb := p->'update';
    v_m    jsonb := p->'update'->'message';
    v_uid  bigint;
    v_kind text;
    v_new  boolean;
BEGIN
    IF v_exec IS NULL THEN
        RAISE EXCEPTION 'fn_record_ingress_message: exec_id is required';
    END IF;
    IF jsonb_typeof(v_m) IS DISTINCT FROM 'object'
       OR COALESCE(v_u->>'update_id', '') !~ '^[0-9]+$'
       OR COALESCE(v_m->'chat'->>'id', '') !~ '^-?[0-9]+$'
       OR COALESCE(v_m->>'message_id', '') !~ '^[0-9]+$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'update carries no message with update_id, chat.id and message_id');
    END IF;
    v_uid := (v_u->>'update_id')::bigint;

    -- Befehl wie der Command-Router (JS .trim()): fuehrender Leerraum inkl. Zeilenumbruch zaehlt nicht
    v_kind := CASE
        WHEN jsonb_typeof(v_m->'photo') = 'array' OR jsonb_typeof(v_m->'document') = 'object' THEN 'file'
        WHEN jsonb_typeof(v_m->'text') = 'string' AND (v_m->>'text') !~ '^\s*/' THEN 'text'
        ELSE 'solo'
    END;

    DELETE FROM agent.ingress_buffer WHERE registered_at < clock_timestamp() - interval '2 minutes';

    INSERT INTO agent.ingress_buffer (update_id, chat_id, from_id, message_id, kind, exec_id, payload, claimed_by)
    VALUES (v_uid,
            (v_m->'chat'->>'id')::bigint,
            COALESCE(NULLIF(v_m->'from'->>'id', '')::bigint, (v_m->'chat'->>'id')::bigint),
            (v_m->>'message_id')::bigint,
            v_kind, v_exec,
            CASE WHEN v_kind = 'solo' THEN NULL ELSE v_u END,
            CASE WHEN v_kind = 'solo' THEN v_uid END)
    ON CONFLICT (update_id) DO NOTHING
    RETURNING true INTO v_new;

    RETURN jsonb_build_object('ok', true,
                              'action', CASE WHEN v_new IS NULL THEN 'drop' WHEN v_kind = 'solo' THEN 'process' ELSE 'wait' END,
                              'kind', v_kind,
                              'duplicate', v_new IS NULL);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_record_ingress_message(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_record_ingress_message(JSONB) FROM context_ro;
    END IF;
END $$;
