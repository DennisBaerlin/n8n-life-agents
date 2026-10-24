-- ============================================================
-- agent.fn_normalize_person_languages (read-only, Restore-Helfer)
--   Normiert language je Person einer family.persons[]-Liste (agent.fn_normalize_language). Nicht abbildbar:
--   Owner -> 'de', sonst Key entfernt — dieselbe Regel wie core:V027. Zweck: ein Backup von VOR dem Textkatalog
--   (Freitext-Sprachen) bleibt einspielbar, statt am Validator zu scheitern (core.fn_backup_restore_filtered).
--   RUECKGABE: jsonb-Array gleicher Laenge/Reihenfolge | NULL bei NULL/Nicht-Array
--   Tests: tests/db/core/test_fn_normalize_language.sql, test_fn_backup_restore_filtered.sql (TEST 5)
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_normalize_person_languages(p_persons jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN jsonb_typeof(p_persons) = 'array' THEN COALESCE((
        SELECT jsonb_agg(
                 CASE
                   WHEN jsonb_typeof(e.pp) <> 'object' THEN e.pp
                   WHEN agent.fn_normalize_language(e.pp->>'language') IS NOT NULL
                        THEN e.pp || jsonb_build_object('language', agent.fn_normalize_language(e.pp->>'language'))
                   WHEN e.pp->>'role' = 'owner' THEN e.pp || jsonb_build_object('language', 'de')
                   ELSE e.pp - 'language'
                 END ORDER BY e.ord)
          FROM jsonb_array_elements(p_persons) WITH ORDINALITY AS e(pp, ord)), '[]'::jsonb)
    END;
$$;
