-- ============================================================
-- fn_ui_text (READ-ONLY) — ein fester Nutzertext in einer Sprache
--   Eingabe: p_key text, p_lang text, p_params jsonb (Default {}).
--   Lookup + Fallback-Kette (lang -> 'en' -> der Key selbst) ueber core.fn_ui_texts (eine Regel, nicht dupliziert);
--   danach jede {platzhalter}-Stelle aus p_params in einem Durchlauf ersetzen (ein Wert, der selbst wie ein
--   Platzhalter aussieht, wird nicht erneut ersetzt — gleiche Semantik wie der HITL-Renderer im Workflow); ein
--   fehlender Parameter bleibt als {name} stehen. Konsumenten: DB-seitige feste Texte (Toasts, Knopf-Nachrichten
--   der Callback-Registry, Picker-Toast in agent.fn_set_person_language).
--   Typisierte Werte (core.fn_ui_money/_date/_num/_tpl) rendert die fn selbst in p_lang, damit eine DB-fn
--   Kartenzeilen ({kind:'note', value:<key>, params}) fertig als Text bauen kann: money -> core.fn_fmt_money (sign:true
--   setzt '+' vor positive Betraege; digits:0 ignoriert, SQL zeigt immer zwei Stellen), date -> core.fn_fmt_date,
--   number -> Zahl mit den Nachkommastellen des Werts, Tausender- und Dezimalzeichen wie fn_fmt_money, tpl -> verschachtelter
--   Text; NULL-Wert -> '—' (wie der Workflow-Renderer). Andere Arten (month) -> der Rohwert. Strings unveraendert.
--   Rueckgabe: text
--   Tests: tests/db/core/test_ui_texts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_text(p_key text, p_lang text, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_rest text := core.fn_ui_texts(p_lang, ARRAY[p_key]) ->> p_key;
    v_out  text := '';
    v_m    text[];
    v_pos  int;
    v_v    jsonb;
    v_txt  text;
BEGIN
    v_rest := COALESCE(v_rest, p_key);
    IF jsonb_typeof(p_params) IS DISTINCT FROM 'object' THEN
        RETURN v_rest;
    END IF;
    LOOP
        v_m := regexp_match(v_rest, '\{(\w+)\}');
        EXIT WHEN v_m IS NULL;
        v_pos := position('{' || v_m[1] || '}' IN v_rest);
        v_v := p_params -> v_m[1];
        IF NOT (p_params ? v_m[1]) THEN
            v_txt := '{' || v_m[1] || '}';
        ELSIF jsonb_typeof(v_v) = 'object' AND v_v ? 'kind' THEN
            v_txt := CASE
                WHEN v_v->>'kind' = 'tpl' THEN core.fn_ui_text(v_v->>'value', p_lang, COALESCE(v_v->'params', '{}'::jsonb))
                WHEN jsonb_typeof(v_v->'value') IS DISTINCT FROM 'string' AND jsonb_typeof(v_v->'value') IS DISTINCT FROM 'number' THEN '—'
                WHEN v_v->>'kind' = 'money' THEN
                    CASE WHEN (v_v->>'sign')::boolean AND (v_v->>'value')::numeric > 0 THEN '+' ELSE '' END
                    || core.fn_fmt_money((v_v->>'value')::numeric, v_v->>'currency', p_lang)
                WHEN v_v->>'kind' = 'date' THEN core.fn_fmt_date((v_v->>'value')::date, p_lang)
                WHEN v_v->>'kind' = 'number' THEN
                    CASE WHEN (v_v->>'sign')::boolean AND (v_v->>'value')::numeric > 0 THEN '+' ELSE '' END
                    || (SELECT CASE WHEN COALESCE((SELECT l.locale FROM core.ui_languages l WHERE l.code = p_lang), 'en') ILIKE 'de%'
                                    THEN replace(replace(replace(n, ',', '#'), '.', ','), '#', '.') ELSE n END
                        FROM (SELECT to_char((v_v->>'value')::numeric, 'FM999,999,999,990'
                                     || CASE WHEN scale((v_v->>'value')::numeric) > 0
                                             THEN '.' || repeat('0', scale((v_v->>'value')::numeric)) ELSE '' END) AS n) x)
                ELSE v_v->>'value' END;
        ELSE
            v_txt := COALESCE(p_params ->> v_m[1], '');
        END IF;
        v_out := v_out || substr(v_rest, 1, v_pos - 1) || COALESCE(v_txt, '');
        v_rest := substr(v_rest, v_pos + length(v_m[1]) + 2);
    END LOOP;
    RETURN v_out || v_rest;
END;
$$;
