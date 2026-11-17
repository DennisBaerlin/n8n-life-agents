-- ============================================================
-- core.fn_collect_chat_since() -> TABLE(agent_name text, source_id bigint, content text)
--   Sammelt je Quelltabelle die neuen Owner-Nachrichten seit dem per-Tabelle-Watermark fuer den
--   opt-in Lern-Loop (agent.guide.cron_learn_context). n8n besitzt die agent.<agent>_chat_memory-Tabellen
--   mit je eigener id-Sequenz -> ein Cursor je agent_name (agent.guide_learn_watermark).
--   Core kennt kein Paket:
--     * Quellen = alle agent.*_chat_memory (dynamisch, Muster util_clear_chat_memory) ausser orchestrator
--       (der Verteiler speichert dieselben Nachrichten, die der Fach-Agent bekommt -> Duplikat-Quelle).
--       Ein neuer Paket-Agent dockt ohne Code-Edit an.
--     * Nur Owner-Nachrichten: session_id = Telegram-Chat des Owners (agent.fn_owner_person_id +
--       agent.fn_person_chat_id, dieselbe family-Quelle wie fn_resolve_sender). Owner nicht gepairt ->
--       nichts (fail-closed); sonst koennten Mitglieder-Nachrichten als Vorschlag beim Owner landen.
--     * Fehlende Watermark = 0 (neue Agent-Tabelle: n8n legt sie beim ersten Turn an -> ihr erstes Gespraech
--       zaehlt). Die einmalige Startmarke schon gefuellter Quellen setzt core:V023 (Alt-Historie z. B.
--       career-/estate-Gespraeche geht nie ans Lern-Modell). STABLE, read-only.
--   Rueckgabe: je Zeile agent_name (Quelle ohne Suffix _chat_memory), source_id (m.id), content.
--   Filter (DB entscheidet, nicht das LLM):
--     * m.id > last_seen_id
--     * message->>'type' = 'human'  (KI-Antworten sind kein Lernstoff)
--     * Owner-Text endet vor dem Wechsel-Block des Orchestrators (Kennung v_switch, Gegenstueck in
--       packages/core/build/workflows/agent.orchestrator.ps1 New-AgentCall): die angehaengte Antwort des
--       vorigen Agenten ist kein Owner-Text; content = nur der Satz davor, ohne Satz faellt die Zeile weg
--     * nicht-leerer message->'data'->>'content'
--     * session_id = Owner-Chat (schliesst auch Harness-/Test-Sessions 'test%' aus)
--   Tests: tests/db/core/test_fn_collect_chat_since.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_collect_chat_since()
RETURNS TABLE(agent_name text, source_id bigint, content text)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, agent, core
AS $$
DECLARE
    v_owner   text := agent.fn_person_chat_id(agent.fn_owner_person_id())::text;
    v_tbl     text;
    v_a       text;
    v_wm      bigint;
    -- Gegenstueck: Block-Anfang in agent.orchestrator.ps1 (New-AgentCall). Beide Seiten pruefen denselben Text:
    -- real_ingress ri110 (expect_task_contains) und test_fn_collect_chat_since.
    v_switch  text := E'\n\n[System context, not written by the user';
BEGIN
    IF v_owner IS NULL THEN
        RETURN;   -- Owner nicht gepairt -> keine Owner-Nachrichten identifizierbar (fail-closed)
    END IF;

    FOR v_tbl IN
        SELECT t.tablename FROM pg_catalog.pg_tables t
         WHERE t.schemaname = 'agent' AND t.tablename LIKE '%\_chat\_memory' ESCAPE '\'
           AND t.tablename <> 'orchestrator_chat_memory'
         ORDER BY t.tablename
    LOOP
        v_a := left(v_tbl, length(v_tbl) - length('_chat_memory'));
        SELECT w.last_seen_id INTO v_wm FROM agent.guide_learn_watermark w WHERE w.agent_name = v_a;

        RETURN QUERY EXECUTE format($q$
            SELECT %L::text AS agent_name,
                   m.id::bigint AS source_id,
                   split_part(m.message->'data'->>'content', %L, 1) AS content
            FROM agent.%I m
            WHERE m.id > %s
              AND m.session_id = %L
              AND m.message->>'type' = 'human'
              AND split_part(COALESCE(m.message->'data'->>'content', ''), %L, 1) <> ''
            ORDER BY m.id
        $q$, v_a, v_switch, v_tbl, COALESCE(v_wm, 0), v_owner, v_switch);
    END LOOP;
END;
$$;
