-- ============================================================
-- agent.fn_chat_style (grober Schreibstil eines Chats, read-only)
--   Stufe aus den letzten 20 Nutzer-Nachrichten an den Router (agent.orchestrator_chat_memory, type 'human'), vorher
--   ohne [attachment ...]-Marker und /befehle; leere Reste zaehlen nicht. Konsumenten: Router-Flag user_style
--   (Orchestrator 'Resolve sender', Emoji-Spiegeln) und die Tages-Obergrenze in agent.fn_claim_reaction.
--   Regeln (Konstanten unten): < 5 Nachrichten -> neutral; >= 30 % mit Emoji -> expressive; kein Emoji und
--   Durchschnitt <= 25 Zeichen -> terse; sonst neutral. Emoji = Codepoints U+1F300-1FAFF und U+2600-27BF.
--   SECURITY DEFINER: 'Resolve sender' laeuft unter core_ro, und *_chat_memory steht auf der core_ro-Deny-Liste
--   (util_create_core_ro.sql) -> nur die Stufe verlaesst das Fenster, nie ein Wortlaut. Tabelle fehlt (frische DB,
--   n8n legt sie beim ersten Gebrauch an), NULL-Chat oder jeder Fehler -> 'neutral' (nie RAISE: der Aufrufer ist die
--   Absender-Aufloesung).
--   Rueckgabe: 'expressive' | 'neutral' | 'terse'
--   Tests: tests/db/core/test_fn_chat_style.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_chat_style(p_chat_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    c_window      constant int     := 20;
    c_min_msgs    constant int     := 5;
    c_expr_share  constant numeric := 0.30;
    c_terse_chars constant numeric := 25;
    v_n     int;
    v_emoji int;
    v_avg   numeric;
BEGIN
    IF p_chat_id IS NULL OR to_regclass('agent.orchestrator_chat_memory') IS NULL THEN
        RETURN 'neutral';
    END IF;
    -- EXECUTE, weil die Tabelle beim CREATE der fn fehlen darf; Werte nur als Parameter.
    EXECUTE $q$
        WITH m AS (
            SELECT x.message->>'content' AS c
              FROM agent.orchestrator_chat_memory x
             WHERE x.session_id = $1 AND x.message->>'type' = 'human'
               AND jsonb_typeof(x.message->'content') = 'string'
             ORDER BY x.id DESC
             LIMIT $2),
        t AS (
            SELECT btrim(regexp_replace(regexp_replace(c, '\[attachment[^\]]*\]', ' ', 'g'),
                                        '(^|\s)/[A-Za-z_]+\S*', ' ', 'g')) AS c
              FROM m)
        SELECT count(*)::int,
               (count(*) FILTER (WHERE c ~ '[\U0001F300-\U0001FAFF☀-➿]'))::int,
               avg(char_length(c))
          FROM t
         WHERE c <> ''
    $q$ INTO v_n, v_emoji, v_avg USING p_chat_id::text, c_window;

    IF COALESCE(v_n, 0) < c_min_msgs THEN
        RETURN 'neutral';
    ELSIF v_emoji::numeric / v_n >= c_expr_share THEN
        RETURN 'expressive';
    ELSIF v_emoji = 0 AND v_avg <= c_terse_chars THEN
        RETURN 'terse';
    END IF;
    RETURN 'neutral';
EXCEPTION WHEN OTHERS THEN
    RETURN 'neutral';
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_chat_style(bigint) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_chat_style(BIGINT) FROM context_ro;
    END IF;
END $$;
