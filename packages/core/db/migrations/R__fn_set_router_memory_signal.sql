-- ============================================================
-- fn_set_router_memory_signal (ATOMIC WRITE — Router-Gedaechtnis nach woertlichem Weiterreichen)
--   Der Orchestrator reicht Spezialisten-Antworten woertlich weiter (Relay compose); vom Router verlangt er danach nur
--   das Signal FRAME/NOFRAME. Schreibt der Router doch eine eigene Fassung, sieht der Nutzer sie nie -- das
--   memoryPostgresChat-Gedaechtnis speichert aber genau sie, und die Folge-Turns ahmen sie nach (Live-Befund
--   2026-10-26: Umformulierung statt Signal, selbstverstaerkend). Diese fn ersetzt sie durch das Signal; die Antwort,
--   die der Nutzer sah, steht direkt davor woertlich als tool-Zeile im Gedaechtnis.
--   Nur die JUENGSTE ai-Zeile des Chats, deren Text exakt dem Router-Output entspricht (keine fremde Zeile bei
--   parallelen Laeufen). Tabelle fehlt (frische DB, n8n legt sie beim ersten Gebrauch an) / Signal ungueltig /
--   Text leer = no-op. Idempotent.
--   p: { chat_id, raw (Router-Output dieses Laufs), signal ('FRAME' | 'NOFRAME') }
--   RUECKGABE: {ok:true, updated}
--   Tests: tests/db/core/test_fn_set_router_memory_signal.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_router_memory_signal(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_n int;
BEGIN
    IF to_regclass('agent.orchestrator_chat_memory') IS NULL
       OR COALESCE(p->>'signal', '') NOT IN ('FRAME', 'NOFRAME')
       OR COALESCE(p->>'raw', '') = '' OR COALESCE(p->>'chat_id', '') = '' THEN
        RETURN jsonb_build_object('ok', true, 'updated', false);
    END IF;

    -- Feste Tabelle, Werte nur als Parameter (kein Caller-Input im SQL-Text); EXECUTE, weil die Tabelle beim CREATE
    -- der fn noch fehlen darf.
    EXECUTE $q$
        UPDATE agent.orchestrator_chat_memory m
           SET message = jsonb_set(m.message, '{content}', to_jsonb($3::text))
         WHERE m.id = (SELECT x.id FROM agent.orchestrator_chat_memory x
                        WHERE x.session_id = $1 AND x.message->>'type' = 'ai'
                          AND jsonb_typeof(x.message->'content') = 'string' AND x.message->>'content' = $2
                        ORDER BY x.id DESC LIMIT 1)
           AND m.message->>'content' <> $3   -- steht schon das Signal da (der Normalfall): kein Schreiben
    $q$ USING p->>'chat_id', p->>'raw', p->>'signal';
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'updated', v_n > 0);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_set_router_memory_signal(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_set_router_memory_signal(JSONB) FROM context_ro;
    END IF;
END $$;
