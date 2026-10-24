-- ============================================================
-- core.fn_reminders_overview(p_chat_id) — das Datenmodell des /reminders-Menues (Roter Faden, Paket B)
--   Je Erinnerung der Registry core.cron_labels aus Sicht des BETRACHTERS (Person aus chat_id, nie LLM):
--     { key, package, scope, mandatory, active, enabled, schedule }
--     active   = core.fn_package_active(package) (core immer) — sonst zeigt das Menue "nicht installiert";
--     enabled  = core.fn_reminder_allowed(key, person) — dieselbe Pruef-Adresse wie die Crons (household: Notschalter;
--                person: Notschalter UND eigene Einstellung bzw. Default) — genau das, was die Person bekommt;
--     schedule = core.config schedule.<key> (Cron-Ausdruck; das Menue rendert ihn in Klartext) oder NULL.
--   Sichtbarkeit: der Owner sieht alle Erinnerungen, ein Mitglied nur die Person-Reminder (Haushalts-Erinnerungen
--   schaltet und bekommt der Owner). Unaufgeloester Betrachter -> leere Liste.
--   RUECKGABE: {ok:true, viewer_role, reminders:[...]} (sortiert nach package, key; die Anzeige-Reihenfolge legt der
--   Menue-Build fest).
--   D10 / Auth: SECURITY DEFINER (das Menue liest unter core_ro), search_path gepinnt, alles voll-qualifiziert, kein
--   dynamisches SQL. EXECUTE nur an core_ro (util_create_core_ro.sql).
--   Tests: tests/db/core/test_fn_reminders_overview.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_reminders_overview(p_chat_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_sender jsonb;
    v_pid    text;
    v_role   text;
    v_list   jsonb;
BEGIN
    IF p_chat_id ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(p_chat_id::bigint);
    END IF;
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', true, 'viewer_role', NULL, 'reminders', '[]'::jsonb);
    END IF;
    v_pid  := v_sender->>'person_id';
    v_role := v_sender->>'role';

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'key',       l.cron_key,
               'package',   l.package,
               'scope',     l.scope,
               'mandatory', l.mandatory,
               'active',    l.package = 'core' OR core.fn_package_active(l.package),
               'enabled',   core.fn_reminder_allowed(l.cron_key, v_pid),   -- dieselbe Adresse wie die Crons
               'schedule',  (SELECT c.value FROM core.config c WHERE c.category = 'schedule' AND c.key = l.cron_key))
             ORDER BY l.package, l.cron_key), '[]'::jsonb)
      INTO v_list
      FROM core.cron_labels l
     WHERE v_role = 'owner' OR l.scope = 'person';

    RETURN jsonb_build_object('ok', true, 'viewer_role', v_role, 'reminders', v_list);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_reminders_overview(text) FROM public;
