-- ============================================================
-- core.fn_plan_adult_recipients(p_domain) — wer ueber einen neuen Haushalts-Plan informiert wird (2026-10-28)
--   Die EINE Empfaenger-Regel fuer Owner-Karte (Namen) und Versand: erwachsene Mitglieder = Rolle 'partner' (der Owner
--   veroeffentlicht selbst, Kinder nie), mit Telegram-Verbindung (agent.fn_person_chat_id) und nicht abgemeldet
--   (core.fn_reminder_allowed('plan_news', person) = Notschalter cron_enable.plan_news UND persoenliche Einstellung).
--   Nur fuer eine Domain mit aktivem Haushalts-Plan (core.fn_household_plan_active), sonst leer.
--   RUECKGABE: je Empfaenger (person_id, first_name, chat_id, lang) ORDER BY person_id; first_name aus den family-Fakten
--   (Anzeige auf der Owner-Karte), lang = agent.fn_person_lang (Sprache fester Texte).
--   STABLE, SECURITY DEFINER, search_path gepinnt; LANGUAGE plpgsql (ruft alphabetisch spaetere R__-fns).
--   Tests: tests/db/core/test_fn_plan_share_targets.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_adult_recipients(p_domain text)
RETURNS TABLE (person_id text, first_name text, chat_id text, lang text)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.fn_household_plan_active(p_domain)) THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT ap.person_id,
           COALESCE((SELECT pp->>'first_name' FROM agent.core_contexts c,
                            jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
                      WHERE c.name = 'family' AND pp->>'person_id' = ap.person_id LIMIT 1), ap.full_name, ap.person_id),
           ch.chat::text,
           agent.fn_person_lang(ap.person_id)->>'lang'
    FROM agent.persons ap
    CROSS JOIN LATERAL (SELECT agent.fn_person_chat_id(ap.person_id) AS chat) ch
    WHERE ap.role = 'partner'
      AND ch.chat IS NOT NULL
      AND core.fn_reminder_allowed('plan_news', ap.person_id)
    ORDER BY ap.person_id;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_plan_adult_recipients(text) FROM public;
