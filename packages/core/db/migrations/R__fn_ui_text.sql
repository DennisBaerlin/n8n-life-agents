-- ============================================================
-- core.fn_ui_text (read-only, ein fester Nutzertext in einer Sprache)
--   Lookup + Fallback-Kette (lang -> 'en' -> der Key selbst) ueber core.fn_ui_texts (EINE Regel, nicht dupliziert);
--   danach jede {platzhalter}-Stelle aus p_params in EINEM Durchlauf ersetzen (ein Wert, der selbst wie ein
--   Platzhalter aussieht, wird nicht erneut ersetzt — gleiche Semantik wie der HITL-Renderer im Workflow); ein
--   fehlender Parameter bleibt als {name} stehen. Konsumenten: DB-seitige feste Texte (Picker-Toast in
--   agent.fn_set_person_language; spaeter Begruessung/Toasts der Phase B).
--   RUECKGABE: text
--   Tests: tests/db/core/test_ui_texts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_text(p_key text, p_lang text, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_rest text := core.fn_ui_texts(p_lang, ARRAY[p_key]) ->> p_key;
    v_out  text := '';
    v_m    text[];
    v_pos  int;
BEGIN
    v_rest := COALESCE(v_rest, p_key);
    IF jsonb_typeof(p_params) IS DISTINCT FROM 'object' THEN
        RETURN v_rest;
    END IF;
    LOOP
        v_m := regexp_match(v_rest, '\{(\w+)\}');
        EXIT WHEN v_m IS NULL;
        v_pos := position('{' || v_m[1] || '}' IN v_rest);
        v_out := v_out || substr(v_rest, 1, v_pos - 1)
              || CASE WHEN p_params ? v_m[1] THEN COALESCE(p_params ->> v_m[1], '') ELSE '{' || v_m[1] || '}' END;
        v_rest := substr(v_rest, v_pos + length(v_m[1]) + 2);
    END LOOP;
    RETURN v_out || v_rest;
END;
$$;
