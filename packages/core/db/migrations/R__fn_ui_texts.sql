-- ============================================================
-- core.fn_ui_texts (read-only, Text-Buendel fuer Workflows)
--   Key -> Text fuer eine Liste von Keys in einer Sprache, Fallback-Kette wie core.fn_ui_text (lang -> 'en' -> Key
--   selbst), OHNE Platzhalter-Ersetzung (die macht der Workflow-Renderer mit den Laufzeitwerten). Ein Aufruf je
--   Empfaenger statt eines DB-Knotens je Text. Laeuft unter core_ro (HITL-Gate) -> Perspektiv-Test in
--   tests/db/cross/test_role_permissions.sql.
--   RUECKGABE: jsonb-Objekt {key: text} (leere Liste -> {})
--   Tests: tests/db/core/test_ui_texts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_texts(p_lang text, p_keys text[])
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_object_agg(k.key, COALESCE(
               (SELECT t.text FROM core.ui_texts t
                 WHERE t.key = k.key AND t.lang IN (p_lang, 'en')
                 ORDER BY (t.lang = p_lang) DESC LIMIT 1),
               k.key)), '{}'::jsonb)
      FROM (SELECT DISTINCT unnest(p_keys) AS key) k
     WHERE k.key IS NOT NULL;
$$;
