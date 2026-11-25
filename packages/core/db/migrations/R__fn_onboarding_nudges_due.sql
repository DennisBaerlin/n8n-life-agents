-- ============================================================
-- fn_onboarding_nudges_due (WRITE)
--   Sanftes Nachfassen bei liegengebliebenem Einrichten: nach 3 Tagen Stillstand eine Karte, nach 10 Tagen eine
--   letzte, dann Ruhe, bis neue offene Abschnitte entstehen (Paket installiert). Sequenz mit Exit-Regel +
--   dauerhafte Abmeldung als Praeferenz, Dedup ueber die geteilte Latch-Schicht (kein eigener Journey-Store).
--   p: { order: ["core","finance",...] }  = Menue-Reihenfolge der Bereiche (build-time $OnboardingPackageOrder, vom
--      Cron eingesetzt) -> die Karte zeigt denselben naechsten Schritt wie der 👉-Knopf des /onboarding-Menues.
--      Pakete ausserhalb von order stehen hinten, danach zaehlt nur ord.
--   Je Person mit Telegram-Verbindung (agent.persons + agent.fn_person_chat_id):
--     * relevant = die Sicht von core.fn_onboarding_overview(chat_id): Owner alle Abschnitte, Mitglied nur per_user-
--       Abschnitte, deren for_roles seine Rolle nennt (NULL = alle), und erst, wenn der Haushalt fertig ist (vorher
--       richtet der Owner ein). Dieselbe Rollen-Regel wie core.fn_get_next_step.
--     * nichts offen -> nichts. core.fn_reminder_allowed('onboarding_nudge', person) = false -> nichts (vor jedem
--       Latch: eine Abmeldung verbraucht keine Stufe).
--     * Stillstand = now() - letzter Fortschritt; letzter Fortschritt = max(status_changed_at) der relevanten
--       Abschnitte; fuer Mitglieder mindestens der Zeitpunkt "Haushalt fertig" bzw. der Einloese-Zeitpunkt der
--       Einladung (agent.pairing_state.claimed_at) -> nie eine Karte am Tag der Verbindung.
--     * Owner: ist sein naechster Schritt eine angefangene Beratung (core.fn_get_next_step kind plan, state draft:
--       "Angefangenes geht vor"), schweigt die Karte; dieselbe Tor-Logik wie die Beratungs-Erinnerung, gespiegelt.
--     * Stufen ueber core.fn_nudge_stage (source 'onboarding_nudge', Merker '<pid>:1'/'<pid>:2', Slot
--       'onboarding_nudge'): Stufe 1 nach >= 3 Tagen Stillstand, Stufe 2 nach >= 10 Tagen und >= 7 Tage nach Stufe 1;
--       Re-Arm sofort (Abstand 0), wenn ein offener relevanter Abschnitt juenger ist als die letzte Karte (neues Paket,
--       neu geoeffneter Abschnitt). Budget, Pause, Erinnerungs-Fenster und die Quellen-Grenze (advisor_resume hat der
--       Person heute schon geschrieben -> heute nichts) lassen die Stufe unverbraucht.
--     * hoechstens eine Karte je Person und Lauf: der erste offene Abschnitt in p.order-Reihenfolge, dann ord.
--   RUECKGABE: {ok:true, nudges:[{person_id, chat_id, stage, package, section_key}]} (immer genau eine Zeile; der Cron
--     faechert im Code-Node). VOLATILE (schreibt Latches) -> im Cron einmal in einer MATERIALIZED CTE aufrufen.
--   INVOKER: laeuft unter der Core-Host-Cred des Crons (liest agent.* + ueber die DEFINER-Fenster alle Bereiche).
--   search_path gepinnt, alle Refs voll-qualifiziert, kein dynamisches SQL.
--   Tests: tests/db/core/test_fn_onboarding_nudges_due.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_onboarding_nudges_due(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_order     text[] := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p->'order', '[]'::jsonb)));
    v_src       constant text := 'onboarding_nudge';
    v_out       jsonb := '[]'::jsonb;
    v_household boolean;
    v_house_at  timestamptz;
    r           record;
    v_chat      bigint;
    v_owner     boolean;
    v_secs      jsonb;
    v_next      jsonb;
    v_last      timestamptz;
    v_rearm     timestamptz;
    v_step      jsonb;
    v_stage     int;
BEGIN
    SELECT NOT EXISTS (SELECT 1 FROM agent.guide_onboarding_state WHERE status = 'unknown'),
           max(status_changed_at)
      INTO v_household, v_house_at
      FROM agent.guide_onboarding_state;

    FOR r IN SELECT ap.person_id, ap.role FROM agent.persons ap ORDER BY ap.person_id LOOP
        v_chat := agent.fn_person_chat_id(r.person_id);
        CONTINUE WHEN v_chat IS NULL;
        v_owner := r.role IS NOT DISTINCT FROM 'owner';
        CONTINUE WHEN NOT v_owner AND NOT v_household;

        -- relevante Abschnitte (Menue-Sicht) inkl. Reihenfolge-Index. Noch nicht materialisierte per_user-Zeilen
        -- (changed_at NULL) gelten als geoeffnet, als ihr Paket (zuletzt) aktiviert wurde -> ein neu installiertes
        -- per_user-Paket re-armt auch fuer Mitglieder.
        SELECT COALESCE(jsonb_agg(
                   CASE WHEN s->>'changed_at' IS NULL
                        THEN jsonb_set(s, '{changed_at}', COALESCE(to_jsonb((SELECT COALESCE(r2.activated_at, r2.installed_at)
                                                                             FROM core.package_registry r2
                                                                            WHERE r2.package = s->>'package')), 'null'::jsonb))
                        ELSE s END
                   ORDER BY COALESCE(array_position(v_order, s->>'package'), 999), (s->>'ord')::int), '[]'::jsonb)
          INTO v_secs
          FROM jsonb_array_elements(COALESCE(core.fn_onboarding_overview(v_chat::text)->'sections', '[]'::jsonb)) s
         WHERE v_owner OR ((s->>'per_user')::boolean
                           -- for_roles (aus sections.json geseedet): ein Abschnitt nur fuer diese Rollen, z. B. kein Berufsprofil fuer Kinder
                           AND (jsonb_typeof(s->'for_roles') IS DISTINCT FROM 'array' OR (r.role IS NOT NULL AND (s->'for_roles') ? r.role)));

        SELECT s INTO v_next FROM jsonb_array_elements(v_secs) WITH ORDINALITY AS t(s, i)
         WHERE s->>'status' = 'unknown' ORDER BY i LIMIT 1;
        CONTINUE WHEN v_next IS NULL;
        CONTINUE WHEN NOT core.fn_reminder_allowed('onboarding_nudge', r.person_id);

        -- letzter Fortschritt (Mitglieder: mindestens Haushalt fertig + Einladung eingeloest)
        SELECT max((s->>'changed_at')::timestamptz) INTO v_last FROM jsonb_array_elements(v_secs) s;
        IF NOT v_owner THEN
            v_last := GREATEST(v_last, v_house_at,
                               (SELECT max(ps.claimed_at) FROM agent.pairing_state ps WHERE ps.person_id = r.person_id));
        END IF;
        CONTINUE WHEN v_last IS NULL;

        -- ohne order/plan_order: ob der Schritt ein angefangener Plan ist, haengt nicht von der Reihenfolge ab
        IF v_owner THEN
            v_step := core.fn_get_next_step(jsonb_build_object('chat_id', v_chat::text));
            CONTINUE WHEN v_step->>'kind' = 'plan' AND v_step->>'state' = 'draft';
        END IF;

        SELECT max((s->>'changed_at')::timestamptz) INTO v_rearm FROM jsonb_array_elements(v_secs) s WHERE s->>'status' = 'unknown';
        v_stage := core.fn_nudge_stage(jsonb_build_object(
            'source', v_src, 'key_prefix', r.person_id, 'person_id', r.person_id, 'slot', 'onboarding_nudge',
            'idle_since', v_last, 'rearm_since', v_rearm, 'first_days', 3, 'last_days', 10, 'gap_days', 7, 'rearm_days', 0,
            'exclusive_sources', jsonb_build_array('advisor_resume')));
        IF v_stage IS NOT NULL THEN
            v_out := v_out || jsonb_build_object('person_id', r.person_id, 'chat_id', v_chat, 'stage', v_stage,
                                                 'package', v_next->>'package', 'section_key', v_next->>'key');
        END IF;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'nudges', v_out);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_onboarding_nudges_due(jsonb) FROM public;
