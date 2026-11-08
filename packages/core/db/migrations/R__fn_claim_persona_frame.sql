-- ============================================================
-- agent.fn_claim_persona_frame (fester Rahmensatz vor einer Spezialisten-Antwort)
--   Waehlt den Katalog-Satz, den der Orchestrator bei Persona != neutral und Router-Signal FRAME vor die woertlich
--   weitergereichte Spezialisten-Antwort setzt (kein LLM, nie Modelltext neben Zahlen).
--   Zero-Trust: Persona, Sprache und Vorname kommen aus agent.fn_resolve_sender(p->>'chat_id').
--   Auswahl:
--     1. Persona neutral, Signal != FRAME oder keine Spezialisten-Teile (has_parts) -> kein Satz.
--     2. Tagesgruss: erste solche Antwort des lokalen Tages je Person (Latch core.fn_should_notify source
--        'persona_greet', key '<pid>:<core.fn_today()>') -> core.persona.greet.<persona>.<core.fn_daypart()>.
--        Ohne Vorname oder ohne Gruss-Key: kein Latch, weiter mit 3.
--     3. Rahmensatz: Keys core.persona.frame.<persona>.* (nach Key sortiert), Index message_id % Anzahl.
--        Ohne Vorname nur Saetze ohne {name}.
--   Texte direkt aus core.ui_texts (Sprache der Person, sonst en) — core.fn_ui_texts gaebe fuer einen fehlenden Key
--   den Key selbst zurueck. {name} -> Vorname. Alte persona_greet-Latches der Person loescht derselbe Aufruf.
--   p: {chat_id, signal, has_parts, message_id}
--   RUECKGABE: {ok:true, text:text|null}  (nie RAISE -> ein Fehler kostet nur den Rahmensatz)
--   Tests: tests/db/core/test_fn_claim_persona_frame.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_claim_persona_frame(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    c_src     constant text := 'persona_greet';
    c_keys    constant text := 'core.persona.';   -- Familien greet.<persona>.<daypart> und frame.<persona>.<n> (Katalog von Paket core)
    v_none    constant jsonb := jsonb_build_object('ok', true, 'text', NULL);
    v_chat    bigint;
    v_msg     bigint;
    v_sender  jsonb;
    v_pid     text;
    v_persona text;
    v_name    text;
    v_lang    text;
    v_today   text;
    v_prefix  text;
    v_texts   text[];
    v_text    text;
BEGIN
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
        v_msg  := COALESCE(NULLIF(p->>'message_id', '')::bigint, 0);
    EXCEPTION WHEN OTHERS THEN
        RETURN v_none;
    END;
    IF upper(btrim(COALESCE(p->>'signal', ''))) <> 'FRAME'
       OR COALESCE((p->>'has_parts')::boolean, false) IS NOT TRUE THEN
        RETURN v_none;
    END IF;
    v_sender := agent.fn_resolve_sender(v_chat);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN v_none;
    END IF;
    v_persona := COALESCE(v_sender->>'persona', 'neutral');
    IF v_persona = 'neutral' THEN
        RETURN v_none;
    END IF;
    v_pid   := v_sender->>'person_id';
    v_name  := NULLIF(btrim(COALESCE(v_sender->>'first_name', '')), '');
    v_lang  := COALESCE(agent.fn_person_lang(v_pid)->>'lang', 'en');
    v_today := v_pid || ':' || core.fn_today()::text;

    DELETE FROM core.notification_state n
     WHERE n.source = c_src AND split_part(n.key, ':', 1) = v_pid AND n.key <> v_today;

    IF v_name IS NOT NULL THEN
        SELECT t.text INTO v_text
          FROM core.ui_texts t
         WHERE t.key = c_keys || 'greet.' || v_persona || '.' || core.fn_daypart()
           AND t.lang IN (v_lang, 'en')
         ORDER BY (t.lang = v_lang) DESC
         LIMIT 1;
        IF v_text IS NOT NULL AND core.fn_should_notify(c_src, v_today, NULL) THEN
            RETURN jsonb_build_object('ok', true, 'text', replace(v_text, '{name}', v_name));
        END IF;
    END IF;

    -- Rahmensaetze in genau einer Sprache (Person, sonst en): eine Misch-Liste verschoebe die Rotation.
    v_prefix := c_keys || 'frame.' || v_persona || '.';
    SELECT array_agg(t.text ORDER BY t.key) INTO v_texts
      FROM core.ui_texts t
     WHERE left(t.key, length(v_prefix)) = v_prefix
       AND t.lang = (SELECT x.lang FROM core.ui_texts x
                      WHERE left(x.key, length(v_prefix)) = v_prefix AND x.lang IN (v_lang, 'en')
                      ORDER BY (x.lang = v_lang) DESC LIMIT 1)
       AND t.text <> ''
       AND (v_name IS NOT NULL OR strpos(t.text, '{name}') = 0);
    IF COALESCE(cardinality(v_texts), 0) = 0 THEN
        RETURN v_none;
    END IF;
    v_text := v_texts[1 + (abs(v_msg) % cardinality(v_texts))::int];
    RETURN jsonb_build_object('ok', true, 'text', replace(v_text, '{name}', COALESCE(v_name, '')));
EXCEPTION WHEN OTHERS THEN
    RETURN v_none;
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_claim_persona_frame(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_claim_persona_frame(JSONB) FROM context_ro;
    END IF;
END $$;
