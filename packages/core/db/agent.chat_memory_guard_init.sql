-- agent.chat_memory_guard_init.sql — Gesetz: agent.*_chat_memory traegt keine thinking-/redacted_thinking-Bloecke.
--   Grund: die Signatur eines Denkblocks gilt nur fuer den unveraenderten Gespraechsanfang (Anthropic "preserved thinking");
--   das Memory-Fenster und ein neu gerenderter System-Prompt aendern ihn -> 400 beim Zurueckspielen. Text und Tool-Bloecke
--   bleiben. Die laufende Tool-Schleife liest aus dem Lauf selbst, nicht aus dieser Tabelle (saveToMemory erst nach der Antwort).
--   Die Sperre sitzt in der DB statt im prüfsummengebundenen n8n-Patch: sie gilt fuer jeden Schreiber und ueberlebt einen n8n-Pin-Wechsel.
--   Der n8n-Knoten legt die Tabellen zur Laufzeit an -> Event-Trigger; das Init haengt den Trigger an alle schon vorhandenen.
CREATE SCHEMA IF NOT EXISTS agent;

CREATE OR REPLACE FUNCTION agent.fn_strip_thinking_blocks(p_message jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN jsonb_typeof(p_message->'content') = 'array'
             AND p_message->'content' @? '$[*] ? (@.type == "thinking" || @.type == "redacted_thinking")'
        -- Ein leeres Inhalts-Array lehnt die API ab -> leerer Text.
        THEN jsonb_set(p_message, '{content}', COALESCE(
                (SELECT jsonb_agg(b ORDER BY ord)
                   FROM jsonb_array_elements(p_message->'content') WITH ORDINALITY AS x(b, ord)
                  WHERE COALESCE(b->>'type', '') NOT IN ('thinking', 'redacted_thinking')),
                '""'::jsonb))
        ELSE p_message
    END
$$;

-- DEFINER: die Schreiber sind verschiedene enge Rollen; EXECUTE auf die Hilfs-fn wird beim Feuern geprueft.
CREATE OR REPLACE FUNCTION agent.fn_chat_memory_strip_thinking()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    NEW.message := agent.fn_strip_thinking_blocks(NEW.message);
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION agent.fn_chat_memory_strip_thinking() FROM public;

-- Nur Tabellen mit jsonb-Spalte message: ein Fehler hier wuerde das CREATE TABLE des n8n-Knotens und damit den Agenten-Lauf abbrechen.
CREATE OR REPLACE FUNCTION agent.fn_chat_memory_attach_guard(p_table regclass)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = p_table AND a.attname = 'message' AND NOT a.attisdropped AND a.atttypid = 'jsonb'::regtype)
       AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                        WHERE t.tgrelid = p_table AND t.tgname = 'trg_chat_memory_strip_thinking' AND NOT t.tgisinternal) THEN
        EXECUTE format('CREATE TRIGGER trg_chat_memory_strip_thinking BEFORE INSERT OR UPDATE OF message ON %s '
                       'FOR EACH ROW EXECUTE FUNCTION agent.fn_chat_memory_strip_thinking()', p_table);
    END IF;
END $$;
REVOKE ALL ON FUNCTION agent.fn_chat_memory_attach_guard(regclass) FROM public;

-- DEFINER: der Knoten legt die Tabelle mit der n8n-Rolle an, die weder diese Funktionen noch ein Recht auf Trigger anderer Rollen hat.
CREATE OR REPLACE FUNCTION agent.fn_chat_memory_guard_ddl()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT c.objid::regclass AS tbl
               FROM pg_event_trigger_ddl_commands() c
               JOIN pg_class k ON k.oid = c.objid
              WHERE c.object_type = 'table' AND c.schema_name = 'agent' AND right(k.relname, 12) = '_chat_memory'
    LOOP
        PERFORM agent.fn_chat_memory_attach_guard(r.tbl);
    END LOOP;
END $$;
REVOKE ALL ON FUNCTION agent.fn_chat_memory_guard_ddl() FROM public;

-- Im DO-Block, weil sqlfluff EVENT TRIGGER nicht parst.
DO $$
BEGIN
    DROP EVENT TRIGGER IF EXISTS chat_memory_guard_ddl;
    CREATE EVENT TRIGGER chat_memory_guard_ddl ON ddl_command_end WHEN TAG IN ('CREATE TABLE')
        EXECUTE FUNCTION agent.fn_chat_memory_guard_ddl();
END $$;

DO $$
DECLARE v_tbl regclass;
BEGIN
    FOR v_tbl IN SELECT format('agent.%I', tablename)::regclass FROM pg_tables
                  WHERE schemaname = 'agent' AND right(tablename, 12) = '_chat_memory'
    LOOP
        PERFORM agent.fn_chat_memory_attach_guard(v_tbl);
    END LOOP;
END $$;

-- Bestand bereinigen (V036, idempotent): Denkbloecke aus allen Zeilen, handgesetzte Vorgaenger der Sperre abraeumen.
--   Rueckgabe: Zahl der bereinigten Zeilen.
CREATE OR REPLACE FUNCTION agent.fn_chat_memory_cleanup()
RETURNS bigint LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tbl text; v_n bigint; v_total bigint := 0; v_evt name;
BEGIN
    FOR v_evt IN SELECT e.evtname FROM pg_event_trigger e JOIN pg_proc p ON p.oid = e.evtfoid
                  WHERE e.evtname <> 'chat_memory_guard_ddl' AND p.prosrc LIKE '%strip_thinking%'
    LOOP
        EXECUTE format('DROP EVENT TRIGGER %I', v_evt);
    END LOOP;
    FOR v_tbl IN SELECT tablename FROM pg_tables WHERE schemaname = 'agent' AND right(tablename, 12) = '_chat_memory'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS strip_thinking ON agent.%I', v_tbl);
        IF EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'agent' AND table_name = v_tbl AND column_name = 'message' AND data_type = 'jsonb') THEN
            EXECUTE format($q$UPDATE agent.%I SET message = agent.fn_strip_thinking_blocks(message)
                               WHERE message->'content' @? '$[*] ? (@.type == "thinking" || @.type == "redacted_thinking")'$q$, v_tbl);
            GET DIAGNOSTICS v_n = ROW_COUNT;
            v_total := v_total + v_n;
        END IF;
    END LOOP;
    RETURN v_total;
END $$;
