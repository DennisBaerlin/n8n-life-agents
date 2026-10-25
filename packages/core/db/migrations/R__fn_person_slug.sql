-- ============================================================
-- agent.fn_person_slug (die EINE Adresse fuer "neue person_id aus dem Vornamen")
--   Slugs vergibt die DB, nie das LLM (.claude/rules/sql.md: Slugs/IDs vergibt die fn). Aus dem Vornamen:
--   Umlaute ae/oe/ue/ss, gaengige Akzente per translate, alles Nicht-[a-z0-9_] -> '_', Raender getrimmt;
--   leer (z. B. nur Hangul) -> Fallback 'person'. Eindeutig (_2/_3 …) gegen
--     (1) die LIVE family.facts.persons[],
--     (2) p_taken (im selben Write schon vergebene/vorhandene ids — fn_set_context_facts reicht seinen Merge-Stand),
--     (3) Reste '<base>__<slug>' in agent.core_contexts (per_user-Zeilen einer entfernten Person: eine neue Person
--         gleichen Namens erbte sonst still deren Karriere-/Profil-Daten).
--   Aufrufer: fn_add_household_person (CLI), fn_set_context_facts (family, Chat-Pfad, Person ohne person_id).
--   STABLE (liest nur). Tests: tests/db/core/test_fn_household_person.sql, test_fn_set_context_facts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_person_slug(p_first text, p_taken text[] DEFAULT '{}')
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base TEXT;
    v_slug TEXT;
    v_n    INT := 1;
BEGIN
    v_base := lower(btrim(COALESCE(p_first, '')));
    v_base := replace(replace(replace(replace(v_base, 'ä', 'ae'), 'ö', 'oe'), 'ü', 'ue'), 'ß', 'ss');
    v_base := translate(v_base, 'áàâãåéèêëíìîïóòôõøúùûñçýÿ', 'aaaaaeeeeiiiiooooouuuncyy');
    v_base := regexp_replace(v_base, '[^a-z0-9_]+', '_', 'g');
    v_base := COALESCE(NULLIF(btrim(v_base, '_'), ''), 'person');

    v_slug := v_base;
    WHILE v_slug = ANY (COALESCE(p_taken, '{}'))
       OR EXISTS (SELECT 1 FROM agent.core_contexts c,
                         jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
                   WHERE c.name = 'family' AND pp->>'person_id' = v_slug)
       OR EXISTS (SELECT 1 FROM agent.core_contexts c
                   WHERE right(c.name, length(v_slug) + 2) = '__' || v_slug) LOOP
        v_n := v_n + 1;
        v_slug := v_base || '_' || v_n;
    END LOOP;
    RETURN v_slug;
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_person_slug(text, text[]) FROM public;
