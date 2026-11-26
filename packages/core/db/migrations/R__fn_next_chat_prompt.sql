-- ============================================================
-- core.fn_next_chat_prompt(p) — welche offene Frage der Orchestrator jetzt senden soll (WRITE: Status, Sweep)
--   Der Orchestrator ruft sie am Ende jedes Laufs eines Privatchats und im Knopf-Arm nach then:'next' (die offene Frage
--   steht immer unten im Chat; Senden haengt am Orchestrator). Unter Advisory-Lock je Chat:
--     1. Sweep: erledigte Zeilen (answered/superseded) des Chats, die aelter als 30 Tage sind, werden geloescht.
--     2. Offene Zeile, die vor run_started_at gesendet wurde, und replied=true (der Lauf hat geantwortet):
--          Art choice -> superseded (der Text war die Antwort; die Knoepfe der alten Nachricht sind veraltet);
--          andere Art -> neu senden (resend:true), die alte Nachricht verliert ihre Knoepfe.
--        Eine offene Zeile (nicht choice), deren Senden nie bestaetigt wurde (sent_at NULL), wird erneut geliefert.
--        Sonst bleibt sie stehen: nichts zu senden.
--     3. Keine offene Zeile -> die erste wartende Zeile des juengsten Stapels (nach ord) wird open und gesendet: ein neuer
--        Vorschlag mitten in einem Stapel (Anmerkung zu einem Prüfpunkt) kommt zuerst, danach geht der alte Stapel weiter.
--     4. Nichts wartet -> core.fn_advisor_hint_prompt legt hoechstens einen faelligen Hinweis (Art hint) an.
--   stale_message_ids = Nachrichten, deren Knoepfe der Orchestrator entfernen soll: die eben neu gesendete Zeile und alle
--   Zeilen des Chats, die seit run_started_at superseded wurden und eine message_id tragen; stale = dieselben Nachrichten als
--   [{message_id, card}] (Karte ohne Knoepfe, Form wie core.fn_render_prompt) zum Neuzeichnen.
--   Eingabe p: {chat_id (Pflicht), run_started_at (timestamptz; fehlt -> jetzt), replied (bool)}.
--   Rueckgabe {ok:true, send:false, stale_message_ids, stale} | {ok:true, send:true, prompt_id, kind, resend, card, buttons,
--   stale_message_ids, stale} (card/buttons aus core.fn_render_prompt) | {ok:false, reason} bei ungueltiger chat_id. Nie RAISE.
--   Nach dem Senden: core.fn_chat_prompt_sent({prompt_id, message_id}) (Familie dieser Datei).
--   Familie: core.fn_chat_prompt_sent(p) -> {ok} (message_id + sent_at der offenen Zeile), core.fn_open_chat_prompt(chat_id)
--   -> {id, kind, agent, label} | NULL (Kontext-Kopf des Agenten: open_prompt).
--   VOLATILE, INVOKER (Host-Cred), search_path gepinnt.
--   Tests: tests/db/core/test_chat_prompts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_next_chat_prompt(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_since  timestamptz;
    v_reply  boolean;
    v_open   agent.chat_prompts%ROWTYPE;
    v_id     bigint;
    v_resend boolean := false;
    v_stale  jsonb;
    v_staleo jsonb;
    v_r      jsonb;
BEGIN
    IF NOT core.fn_chat_id_ok(v_chat) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_chat_id');
    END IF;
    BEGIN
        v_since := COALESCE(NULLIF(p->>'run_started_at', '')::timestamptz, clock_timestamp());
        v_reply := COALESCE(NULLIF(p->>'replied', '')::boolean, false);
    EXCEPTION WHEN OTHERS THEN
        v_since := clock_timestamp();
        v_reply := false;
    END;
    PERFORM pg_advisory_xact_lock(hashtext('chat_prompt:' || v_chat));

    DELETE FROM agent.chat_prompts
     WHERE chat_id = v_chat AND status IN ('answered', 'superseded') AND decided_at < now() - interval '30 days';

    SELECT * INTO v_open FROM agent.chat_prompts WHERE chat_id = v_chat AND status = 'open' FOR UPDATE;
    IF FOUND THEN
        IF v_reply AND v_open.sent_at IS NOT NULL AND v_open.sent_at < v_since THEN
            IF v_open.kind = 'choice' THEN
                UPDATE agent.chat_prompts SET status = 'superseded', decided_at = clock_timestamp() WHERE id = v_open.id;
            ELSE
                v_id := v_open.id;
                v_resend := true;
            END IF;
        ELSIF v_open.sent_at IS NULL AND v_open.kind <> 'choice' THEN
            v_id := v_open.id;   -- geoeffnet, aber das Senden ist nie bestaetigt worden
        END IF;
    END IF;

    IF v_id IS NULL AND NOT EXISTS (SELECT 1 FROM agent.chat_prompts WHERE chat_id = v_chat AND status = 'open') THEN
        SELECT q.id INTO v_id
          FROM agent.chat_prompts q
         WHERE q.chat_id = v_chat AND q.status = 'queued'
         ORDER BY (SELECT max(b.id) FROM agent.chat_prompts b WHERE b.batch_id = q.batch_id) DESC, q.ord, q.id
         LIMIT 1;
        IF v_id IS NULL THEN
            BEGIN
                v_id := core.fn_advisor_hint_prompt(v_chat);
            EXCEPTION WHEN OTHERS THEN
                v_id := NULL;
            END;
        END IF;
        IF v_id IS NOT NULL THEN
            UPDATE agent.chat_prompts SET status = 'open' WHERE id = v_id;
        END IF;
    END IF;

    -- Knoepfe entfernt der Telegram-Knoten nur mit Text (editMessageText): darum je Nachricht auch die Karte ohne Knoepfe.
    SELECT COALESCE(jsonb_agg(DISTINCT s.m), '[]'::jsonb),
           COALESCE(jsonb_agg(jsonb_build_object('message_id', s.m, 'card', core.fn_render_prompt(s.id)->'card') ORDER BY s.m), '[]'::jsonb)
      INTO v_stale, v_staleo FROM (
        SELECT DISTINCT ON (c.message_id) c.message_id AS m, c.id FROM agent.chat_prompts c
         WHERE c.chat_id = v_chat AND c.status = 'superseded' AND c.decided_at >= v_since AND c.message_id IS NOT NULL
        UNION
        SELECT v_open.message_id, v_open.id WHERE v_resend AND v_open.message_id IS NOT NULL) s;

    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'send', false, 'stale_message_ids', v_stale, 'stale', v_staleo);
    END IF;
    v_r := core.fn_render_prompt(v_id);
    RETURN jsonb_build_object('ok', true, 'send', true, 'prompt_id', v_id,
        'kind', (SELECT kind FROM agent.chat_prompts WHERE id = v_id), 'resend', v_resend,
        'card', v_r->'card', 'buttons', v_r->'buttons', 'stale_message_ids', v_stale, 'stale', v_staleo);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error', 'send', false);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_next_chat_prompt(jsonb) FROM public;

CREATE OR REPLACE FUNCTION core.fn_chat_prompt_sent(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id bigint;
BEGIN
    UPDATE agent.chat_prompts
       SET message_id = NULLIF(p->>'message_id', '')::bigint, sent_at = clock_timestamp()
     WHERE id = NULLIF(p->>'prompt_id', '')::bigint AND status = 'open'
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', v_id IS NOT NULL, 'prompt_id', v_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error');
END;
$$;
REVOKE ALL ON FUNCTION core.fn_chat_prompt_sent(jsonb) FROM public;

CREATE OR REPLACE FUNCTION core.fn_open_chat_prompt(p_chat_id text)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object('id', c.id, 'kind', c.kind, 'agent', c.agent, 'label', c.payload->>'label')
      FROM agent.chat_prompts c
     WHERE c.chat_id = p_chat_id AND c.status = 'open';
$$;
REVOKE ALL ON FUNCTION core.fn_open_chat_prompt(text) FROM public;
