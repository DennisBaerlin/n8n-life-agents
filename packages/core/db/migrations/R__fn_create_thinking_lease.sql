-- ============================================================
-- fn_create_thinking_lease ("Bot denkt nach"-Schalter)
--   Der Aufrufer (Orchestrator beim Eingang einer Nachricht an die KI, agent.sub_dispatch_agent bei Paket-Befehlen/
--   -Onboarding) ruft sie im privaten Chat, BEVOR er core.sub_show_thinking startet: Zeile (execution, chat) mit
--   expires_at = now() + ttl. JE CHAT EIN SCHALTER (Telegram zeigt je Chat eine Blase): andere Schalter des Chats
--   werden geloescht — auch der liegengebliebene eines abgebrochenen Laufs (ein Abbruch ruft keinen errorWorkflow);
--   deren Schleife endet beim naechsten Claim ('stop'). Raeumt ausserdem Abgelaufene weg. Erneutes Anlegen derselben
--   execution = Upsert. Nicht-numerische chat_id (Test-Sentinel) -> keine Zeile.
--   Fehlende execution_id/ttl_minutes = Bau-Fehler des Aufrufers -> RAISE (nicht nutzerkorrigierbar).
--   p: { chat_id, execution_id, ttl_minutes }
--   RUECKGABE: {ok:true, expires_at} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_thinking_lease.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_create_thinking_lease(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_exec text := NULLIF(trim(p->>'execution_id'), '');
    v_ttl  int;
    v_chat bigint;
    v_exp  timestamptz;
BEGIN
    IF v_exec IS NULL THEN
        RAISE EXCEPTION 'fn_create_thinking_lease: execution_id is required';
    END IF;
    v_ttl := NULLIF(p->>'ttl_minutes', '')::int;
    IF v_ttl IS NULL OR v_ttl <= 0 THEN
        RAISE EXCEPTION 'fn_create_thinking_lease: ttl_minutes must be a positive integer';
    END IF;
    IF COALESCE(p->>'chat_id', '') !~ '^-?[0-9]+$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'chat_id must be numeric');
    END IF;
    v_chat := (p->>'chat_id')::bigint;

    DELETE FROM agent.thinking_lease
     WHERE expires_at <= now() OR (chat_id = v_chat AND execution_id <> v_exec);

    INSERT INTO agent.thinking_lease (execution_id, chat_id, expires_at)
    VALUES (v_exec, v_chat, now() + make_interval(mins => v_ttl))
    ON CONFLICT (execution_id) DO UPDATE
        SET chat_id = EXCLUDED.chat_id, opened_at = now(), expires_at = EXCLUDED.expires_at, drafting_until = NULL
    RETURNING expires_at INTO v_exp;

    RETURN jsonb_build_object('ok', true, 'expires_at', v_exp);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_create_thinking_lease(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_create_thinking_lease(JSONB) FROM context_ro;
    END IF;
END $$;
