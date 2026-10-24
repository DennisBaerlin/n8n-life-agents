-- ============================================================
-- fn_claim_ingress_burst (Telegram-Eingangs-Buendelung, Schritt 2)
--   Der Orchestrator-Eingang ruft sie fuer text/file nach dem kurzen Warten (und bei action 'wait' erneut).
--   Entscheidet, ob DIESER Lauf seine Nachricht verarbeitet, weiter wartet oder still endet:
--     Zeile fehlt (record gescheitert)        -> process (ohne update: der Eingang nimmt das Roh-Update; fail-open)
--     exec_id fremd (Webhook-Retry)           -> drop, reason duplicate
--     solo (legt record selbst-beansprucht an) -> process
--     schon beansprucht                       -> drop, reason claimed (ein anderer Lauf verarbeitet sie)
--     text/file: Buendel = eigene Zeile + unbeanspruchte text/file-Zeilen desselben (chat, from) mit
--       registered_at von 2 s VOR bis 10 s NACH der EIGENEN Ankunft (nie relativ zur Uhr: eine verspaetete
--       eigene Zeile geht nie verloren; nur 2 s zurueck: eine aeltere unbeanspruchte Zeile ist sonst die eines
--       Laufs, der nach einem DB-Fehler schon fail-open allein lief -> nicht ein zweites Mal verarbeiten).
--       Juengste Ankunft < 1 s her UND eigene < 5 s her UND nicht final -> wait (gleitendes Fenster, Obergrenze
--       5 s; final = letzte Runde der Graph-Schleife -> nie mehr wait). Sonst: eigene Zeile ist eine Datei, aber
--       nicht die frueheste des Buendels -> nur sich selbst (process). Andernfalls alle Texte + die frueheste
--       Datei beanspruchen und EIN Update bauen: Primaer = frueheste Datei (sonst fruehester Text),
--       Texte/Bildunterschriften in message_id-Reihenfolge mit Leerzeile -> caption (bzw. text ohne Datei);
--       entities/caption_entities fallen weg (ihre Offsets passten nicht mehr). update nur, wenn > 1 Zeile.
--   Beanspruchte Zeilen: claimed_by = eigene update_id, payload = NULL (Privatsphaere). Raeumt Zeilen > 2 min weg.
--   NEBENLAEUFIGKEIT: erste Anweisung ist ein EIGENES PERFORM pg_advisory_xact_lock(<Namensraum>, <chat>)
--   (VOLATILE-fn -> jede folgende Anweisung sieht unter READ COMMITTED einen frischen Schnappschuss NACH dem
--   Lock). Claims desselben Chats laufen so strikt nacheinander; record nimmt den Lock nicht (es legt nur
--   neue Zeilen an). Zeitbasis clock_timestamp(), nicht now().
--   Fehlende exec_id = Bau-Fehler des Aufrufers -> RAISE (der Eingang ist fail-open).
--   p: { update_id, exec_id, final? }
--   RUECKGABE: {ok:true, action: process|wait|drop, update?, merged_update_ids?, reason?}
--   Tests: tests/db/core/test_fn_ingress_buffer.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_claim_ingress_burst(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_exec    text := NULLIF(trim(p->>'exec_id'), '');
    v_uid     bigint;
    v_chat    bigint;
    v_row     agent.ingress_buffer%ROWTYPE;
    v_now     timestamptz;
    v_young   timestamptz;
    v_burst   bigint[];   -- Kandidaten (unbeanspruchte text/file-Zeilen im Fenster + eigene)
    v_file    bigint;     -- update_id der fruehesten Datei im Buendel
    v_ids     bigint[];   -- tatsaechlich beanspruchte Zeilen
    v_primary jsonb;
    v_text    text;
    v_msg     jsonb;
BEGIN
    IF v_exec IS NULL THEN
        RAISE EXCEPTION 'fn_claim_ingress_burst: exec_id is required';
    END IF;
    IF COALESCE(p->>'update_id', '') !~ '^[0-9]+$' THEN
        RETURN jsonb_build_object('ok', false, 'action', 'process', 'reason', 'update_id must be numeric');
    END IF;
    v_uid := (p->>'update_id')::bigint;

    SELECT chat_id INTO v_chat FROM agent.ingress_buffer WHERE update_id = v_uid;
    IF v_chat IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'action', 'process', 'reason', 'not_recorded');
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('agent.ingress_buffer'), hashtext(v_chat::text));

    SELECT * INTO v_row FROM agent.ingress_buffer WHERE update_id = v_uid;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', true, 'action', 'process', 'reason', 'not_recorded');
    END IF;
    IF v_row.exec_id <> v_exec THEN
        RETURN jsonb_build_object('ok', true, 'action', 'drop', 'reason', 'duplicate');
    END IF;
    IF v_row.kind = 'solo' THEN
        UPDATE agent.ingress_buffer SET claimed_by = v_uid WHERE update_id = v_uid AND claimed_by IS NULL;
        RETURN jsonb_build_object('ok', true, 'action', 'process', 'merged_update_ids', jsonb_build_array(v_uid));
    END IF;
    IF v_row.claimed_by IS NOT NULL THEN
        RETURN jsonb_build_object('ok', true, 'action', 'drop', 'reason', 'claimed', 'claimed_by', v_row.claimed_by);
    END IF;

    DELETE FROM agent.ingress_buffer WHERE registered_at < clock_timestamp() - interval '2 minutes';

    -- Buendel (eigene Zeile immer dabei, auch wenn sie ausserhalb des Fensters laege)
    SELECT array_agg(b.update_id), max(b.registered_at) INTO v_burst, v_young
      FROM agent.ingress_buffer b
     WHERE b.update_id = v_uid
        OR (b.chat_id = v_row.chat_id AND b.from_id = v_row.from_id AND b.kind IN ('text', 'file')
            AND b.claimed_by IS NULL
            AND b.registered_at BETWEEN v_row.registered_at - interval '2 seconds' AND v_row.registered_at + interval '10 seconds');

    v_now := clock_timestamp();
    IF v_young > v_now - interval '1 second' AND v_row.registered_at > v_now - interval '5 seconds'
       AND NOT COALESCE((p->>'final')::boolean, false) THEN
        RETURN jsonb_build_object('ok', true, 'action', 'wait');
    END IF;

    SELECT update_id INTO v_file FROM agent.ingress_buffer
     WHERE update_id = ANY (v_burst) AND kind = 'file' ORDER BY message_id, update_id LIMIT 1;

    IF v_row.kind = 'file' AND v_file IS DISTINCT FROM v_uid THEN
        v_ids := ARRAY[v_uid];
    ELSE
        SELECT array_agg(update_id ORDER BY message_id, update_id) INTO v_ids
          FROM agent.ingress_buffer WHERE update_id = ANY (v_burst) AND (kind = 'text' OR update_id = v_file);
    END IF;

    IF cardinality(v_ids) > 1 THEN
        SELECT payload INTO v_primary FROM agent.ingress_buffer WHERE update_id = COALESCE(v_file, v_ids[1]);
        SELECT string_agg(t, E'\n\n' ORDER BY message_id, update_id) INTO v_text
          FROM (SELECT message_id, update_id,
                       NULLIF(btrim(COALESCE(payload->'message'->>'text', payload->'message'->>'caption', '')), '') AS t
                  FROM agent.ingress_buffer WHERE update_id = ANY (v_ids)) s
         WHERE t IS NOT NULL;
        v_msg := (v_primary->'message') - 'text' - 'caption' - 'entities' - 'caption_entities';
        IF v_text IS NOT NULL THEN
            v_msg := v_msg || jsonb_build_object(CASE WHEN v_file IS NULL THEN 'text' ELSE 'caption' END, v_text);
        END IF;
        v_primary := jsonb_set(v_primary, '{message}', v_msg);
    END IF;

    UPDATE agent.ingress_buffer SET claimed_by = v_uid, payload = NULL WHERE update_id = ANY (v_ids);

    IF cardinality(v_ids) > 1 THEN
        RETURN jsonb_build_object('ok', true, 'action', 'process', 'update', v_primary, 'merged_update_ids', to_jsonb(v_ids));
    END IF;
    RETURN jsonb_build_object('ok', true, 'action', 'process', 'merged_update_ids', to_jsonb(v_ids));
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_claim_ingress_burst(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_claim_ingress_burst(JSONB) FROM context_ro;
    END IF;
END $$;
