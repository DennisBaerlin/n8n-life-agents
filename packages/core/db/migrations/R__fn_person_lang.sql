-- ============================================================
-- agent.fn_person_lang (read-only, Empfaenger-Sprache fester Texte)
--   Sprache + Intl-Locale, in der eine Person feste Texte bekommt. Fallback-Kette (Telegram-Empfehlung "last
--   recorded tag or English"): eigene Sprache -> Owner-Sprache -> 'en'; ein Code, der (nicht mehr) in
--   core.ui_languages steht, zaehlt als fehlend. p_person_id NULL/unbekannt -> Owner-Sprache.
--   Plain INVOKER (core_ro liest agent+core direkt); ein Paket-Rollen-Fenster in core.* erst, wenn ein Paket-Cron
--   es braucht (Muster agent.fn_person_chat_id -> core.fn_person_chat_id).
--   RUECKGABE: {lang, locale}
--   Tests: tests/db/core/test_fn_person_lang.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_person_lang(p_person_id text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH persons AS (
        SELECT pp
          FROM agent.core_contexts c,
               jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
         WHERE c.name = 'family'
    ), cand (prio, code) AS (
        SELECT 1, (SELECT pp->>'language' FROM persons WHERE pp->>'person_id' = p_person_id LIMIT 1)
        UNION ALL
        SELECT 2, (SELECT pp->>'language' FROM persons WHERE pp->>'role' = 'owner' LIMIT 1)
        UNION ALL
        SELECT 3, 'en'
    )
    SELECT COALESCE(
        (SELECT jsonb_build_object('lang', l.code, 'locale', l.locale)
           FROM cand JOIN core.ui_languages l ON l.code = cand.code
          ORDER BY cand.prio
          LIMIT 1),
        jsonb_build_object('lang', 'en', 'locale', 'en-GB'));
$$;
