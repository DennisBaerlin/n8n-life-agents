-- ============================================================
-- agent.fn_normalize_language (read-only, Sprach-Normierung — die EINE Regel fuer freie Sprach-Angaben)
--   Bildet eine freie Angabe ("Deutsch", "Korean", "ko-KR", " DE ") auf einen Code aus core.ui_languages ab:
--   lower(trim()) -> Region abschneiden (ko-kr/de_de -> ko/de) -> Code ODER Alias (core.ui_languages.aliases).
--   Nicht unterstuetzt / leer / NULL -> NULL (der Aufrufer entscheidet: Validator-Ablehnung, Owner-Default, weglassen).
--   Konsumenten: agent.fn_set_context_facts (normiert family.persons[].language vor der Validierung),
--   agent.fn_normalize_person_languages (Restore alter Backups), agent.fn_add_household_person (CLI).
--   core:V027 traegt dieselbe Regel inline (V laeuft vor den R__-fns).
--   RUECKGABE: text (Code) | NULL
--   Tests: tests/db/core/test_fn_normalize_language.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_normalize_language(p_value text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT l.code
      FROM core.ui_languages l
     WHERE NULLIF(trim(p_value), '') IS NOT NULL
       AND (l.code = regexp_replace(lower(trim(p_value)), '^([a-z]{2})[-_][a-z0-9]+$', '\1')
            OR lower(trim(p_value)) = ANY (l.aliases))
     ORDER BY l.ord
     LIMIT 1;
$$;
