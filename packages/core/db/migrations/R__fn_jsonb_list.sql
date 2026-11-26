-- ============================================================
-- core.fn_jsonb_list(p) — Listen-Eingabe eines Werkzeugs als jsonb-Array
--   Werkzeug-Bindungen liefern Listen mal als Array, mal als JSON-String, beim Weglassen als leeren String.
--   NULL, JSON-null und '' -> []; Array -> unveraendert; String -> geparst (muss ein Array ergeben).
--   Alles andere wirft (der Aufrufer faengt es und gibt seine korrigierbare Ablehnung zurueck).
--   Tests: tests/db/core/test_fn_advisor_save_section_fields.sql, tests/db/core/test_chat_prompts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_jsonb_list(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v jsonb := p;
BEGIN
    IF v IS NULL OR jsonb_typeof(v) = 'null' OR (jsonb_typeof(v) = 'string' AND btrim(v #>> '{}') = '') THEN
        RETURN '[]'::jsonb;
    END IF;
    IF jsonb_typeof(v) = 'string' THEN
        v := (v #>> '{}')::jsonb;
    END IF;
    IF jsonb_typeof(v) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'core.fn_jsonb_list: expected a JSON array, got %', jsonb_typeof(v);
    END IF;
    RETURN v;
END;
$$;
