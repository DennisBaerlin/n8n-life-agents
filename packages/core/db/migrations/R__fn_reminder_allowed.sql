-- ============================================================
-- core.fn_reminder_allowed(p_cron_key, p_person_id) — DIE eine Pruef-Adresse "darf Reminder X an Person Y?"
--   (Roter Faden 2026-10-23; etabliertes Muster Knock/Novu-Preferences: zentraler Default + sparse Nutzer-
--   Override, der Admin-Notschalter gewinnt ueber beide).
--   = Notschalter core.config cron_enable.<key> (Paket aus core.cron_labels) = 'true'
--     UND bei scope='person': COALESCE(agent.reminder_prefs.enabled, core.cron_labels.default_enabled).
--   scope='household' -> nur der Notschalter (die Person spielt keine Rolle). Unbekannter Key -> false (fail-closed).
--   Jeder Cron mit Person-Faecherung fragt HIER (nie eigene Praeferenz-Logik).
--   SECURITY DEFINER (liest agent.reminder_prefs + core.config/cron_labels; Paket-Crons laufen unter engen Rollen),
--   STABLE, search_path gepinnt, REVOKE PUBLIC. Grants je Konsument (fn_provision_package_roles), sobald einer existiert.
--   Tests: tests/db/core/test_fn_reminder_prefs.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_reminder_allowed(p_cron_key text, p_person_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE((
        SELECT COALESCE((SELECT c.value FROM core.config c
                          WHERE c.package = l.package AND c.category = 'cron_enable' AND c.key = l.cron_key), 'false') = 'true'
               AND (l.scope = 'household'
                    OR COALESCE((SELECT rp.enabled FROM agent.reminder_prefs rp
                                  WHERE rp.person_id = p_person_id AND rp.cron_key = l.cron_key), l.default_enabled))
          FROM core.cron_labels l
         WHERE l.cron_key = p_cron_key), false);
$$;

REVOKE ALL ON FUNCTION core.fn_reminder_allowed(text, text) FROM public;
