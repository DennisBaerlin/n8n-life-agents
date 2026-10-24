-- Utility (Test/Wartung): leert ALLE agent.*_chat_memory-Tabellen (dynamisch via pg_tables,
-- damit neue Agenten automatisch abgedeckt sind — Muster: util_reset_user_data.sql).
-- Idempotent (nur real existierende Tabellen werden geloopt; n8n legt sie beim ersten Lauf an).
-- Anwenden: scripts\db_apply.ps1 "packages\core\db\util\util_clear_chat_memory.sql"
-- Single-tenant -> TRUNCATE (alle Sessions). Bei Multi-User spaeter auf DELETE WHERE session_id = <chat_id> umstellen.
DO $$
DECLARE t TEXT; n bigint;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables
             WHERE schemaname = 'agent' AND tablename LIKE '%\_chat\_memory' ESCAPE '\'
    LOOP
        EXECUTE format('SELECT count(*) FROM agent.%I', t) INTO n;
        EXECUTE format('TRUNCATE agent.%I', t);
        RAISE NOTICE 'agent.%: geleert (% Zeilen entfernt)', t, n;
    END LOOP;
END $$;
