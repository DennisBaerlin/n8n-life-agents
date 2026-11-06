-- ============================================================
-- core.fn_append_context_note(p jsonb) -> jsonb   (Phase C, WS-3; NEU)
--   Der EINZIGE Prosa-Schreibpfad des Lern-Loops: haengt eine bestaetigte Erkenntnis APPEND-ONLY unter
--   "## Gelernt" an einen Wissens-Kontext, mit Provenienz-Stempel "gelernt am <DATE> aus Chat" (R5-B).
--   HARTER {ok:false}-Allowlist-Guard (R5-A): nur core.fn_note_context_allowed (managed_by='agent' +
--   family oder ein per core.advisors.learn_notes freigegebenes Plan-Dokument) -> der protect-Trigger blockt nur DELETE, NICHT content-UPDATE, also ist
--   DIESER Guard die Sicherung gegen Verhaltens-Korruption von Instruktions-/Seed-Kontexten. owner_only-
--   Backstop (agent.fn_sender_is_member). Beruehrt NUR content (kein metadata.facts); der Validate-Trigger
--   feuert zwar (WHEN NEW.metadata ? 'facts'), prueft unveraenderte facts aber nicht neu. Gelesene p-Keys: { context_name, note, chat_id }. RUECKGABE {ok,context_name,appended}|{ok:false,reason}.
--   INVOKER (Orchestrator-Callback unter Host-RW-Cred). search_path-Pin (CVE-2018-1058) + REVOKE.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_append_context_note(p jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog, agent, core
AS $$
DECLARE
    v_ctx     text := NULLIF(btrim(p->>'context_name'), '');
    v_note    text := NULLIF(regexp_replace(btrim(COALESCE(p->>'note', '')), '\s+', ' ', 'g'), '');
    v_today   text := to_char(CURRENT_DATE, 'YYYY-MM-DD');
    v_line    text;
    v_content text;
    v_lines   text[];
    v_hdr     int := NULL;
    v_i       int;
BEGIN
    IF agent.fn_sender_is_member(p->>'chat_id') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;
    IF v_ctx IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'context_name required');
    END IF;
    IF v_note IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'note is empty');
    END IF;
    -- HARTER Allowlist-Guard (R5-A) — verhindert content-Korruption von Instruktions-/Seed-/Fakten-Kontexten.
    IF NOT core.fn_note_context_allowed(v_ctx) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('context "%s" is not note-appendable (managed_by=agent + knowledge allowlist only)', v_ctx));
    END IF;

    v_line := format('- %s (gelernt am %s aus Chat)', v_note, v_today);

    SELECT content INTO v_content FROM agent.core_contexts WHERE name = v_ctx FOR UPDATE;
    v_content := COALESCE(v_content, '');
    v_lines   := string_to_array(v_content, E'\n');
    IF v_lines IS NOT NULL THEN
        FOR v_i IN 1 .. array_length(v_lines, 1) LOOP
            -- Anker identisch zu core.fn_split_learned_block (exakte Ueberschrift, kein "## Gelerntes …").
            IF v_lines[v_i] ~ '^## Gelernt\s*$' THEN v_hdr := v_i; EXIT; END IF;
        END LOOP;
    END IF;
    IF v_hdr IS NULL THEN
        -- Sektion existiert noch nicht -> am Ende anlegen.
        v_content := rtrim(v_content, E'\n ') || E'\n\n## Gelernt\n\n' || v_line;
    ELSE
        -- direkt NACH der Header-Zeile einfuegen (neueste zuerst).
        v_lines   := v_lines[1:v_hdr] || v_line || v_lines[v_hdr + 1 : array_length(v_lines, 1)];
        v_content := array_to_string(v_lines, E'\n');
    END IF;

    UPDATE agent.core_contexts SET content = v_content WHERE name = v_ctx;

    RETURN jsonb_build_object('ok', true, 'context_name', v_ctx, 'appended', v_line);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_append_context_note(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN REVOKE ALL ON FUNCTION core.fn_append_context_note(jsonb) FROM context_ro; END IF;
END $$;
