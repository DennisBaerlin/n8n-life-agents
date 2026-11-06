-- ============================================================
-- core.fn_onboarding_nudges_due(p) — sanftes Nachfassen bei liegengebliebenem Einrichten (Roter Faden 2026-10-23)
--   Owner-Entscheid: nach 3 Tagen Stillstand eine Karte, nach 10 Tagen eine letzte, dann Ruhe — bis neue offene
--   Abschnitte entstehen (Paket installiert). Etabliertes Muster (arch-challenge): Sequenz mit Exit-Regel +
--   dauerhafte Abmeldung als Praeferenz, Dedup ueber die geteilte Latch-Schicht (kein eigener Journey-Store).
--   p: { order: ["core","finance",...] }  = Menue-Reihenfolge der Bereiche (build-time $OnboardingPackageOrder, vom
--      Cron eingesetzt) -> die Karte zeigt denselben naechsten Schritt wie der 👉-Knopf des /onboarding-Menues.
--   Je Person mit Telegram-Verbindung (agent.persons + agent.fn_person_chat_id):
--     * relevant = die Sicht von core.fn_onboarding_overview(chat_id): Owner alle Abschnitte, Mitglied nur per_user-
--       Abschnitte und erst, wenn der Haushalt fertig ist (vorher richtet der Owner ein).
--     * nichts offen -> nichts. core.fn_reminder_allowed('onboarding_nudge', person) = false -> nichts (VOR jedem
--       Latch: eine Abmeldung verbraucht keine Stufe).
--     * Stillstand = now() - letzter Fortschritt; letzter Fortschritt = max(status_changed_at) der relevanten
--       Abschnitte; fuer Mitglieder mindestens der Zeitpunkt "Haushalt fertig" bzw. der Einloese-Zeitpunkt der
--       Einladung (agent.pairing_state.claimed_at) -> nie eine Karte am Tag der Verbindung.
--     * Re-Arm: ein OFFENER relevanter Abschnitt, dessen status_changed_at juenger ist als die letzte Nachfass-Karte
--       (neues Paket, neu geoeffneter Abschnitt) -> beide Stufen wieder scharf (core.fn_notify_resolve).
--     * Stufe 1: Stillstand >= 3 Tage UND Latch '<pid>:1' frei. Stufe 2: Stillstand >= 10 Tage UND Stufe 1 vor
--       >= 7 Tagen gesendet UND Latch '<pid>:2' frei. Latch source 'onboarding_nudge' (core.fn_should_notify, NULL-TTL).
--     * hoechstens EINE Karte je Person und Lauf: der erste offene Abschnitt in p.order-Reihenfolge, dann ord.
--   RUECKGABE: {ok:true, nudges:[{person_id, chat_id, stage, package, section_key}]} (immer genau eine Zeile; der Cron
--     faechert im Code-Node). VOLATILE (schreibt Latches) -> im Cron EINMAL in einer MATERIALIZED CTE aufrufen.
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
    v_idle      interval;
    v_s1_state  text;
    v_s1_at     timestamptz;
    v_fired_at  timestamptz;
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
        -- per_user-Paket re-armt auch fuer Mitglieder (Review-Fund).
        SELECT COALESCE(jsonb_agg(
                   CASE WHEN s->>'changed_at' IS NULL
                        THEN jsonb_set(s, '{changed_at}', COALESCE(to_jsonb((SELECT COALESCE(r2.activated_at, r2.installed_at)
                                                                             FROM core.package_registry r2
                                                                            WHERE r2.package = s->>'package')), 'null'::jsonb))
                        ELSE s END
                   ORDER BY COALESCE(array_position(v_order, s->>'package'), 999), (s->>'ord')::int), '[]'::jsonb)
          INTO v_secs
          FROM jsonb_array_elements(COALESCE(core.fn_onboarding_overview(v_chat::text)->'sections', '[]'::jsonb)) s
         WHERE v_owner OR (s->>'per_user')::boolean;

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
        v_idle := now() - v_last;

        -- Re-Arm: offener Abschnitt juenger als die letzte Nachfass-Karte (neues Paket / wieder geoeffnet)
        SELECT max(ns.last_fired_at) INTO v_fired_at FROM core.notification_state ns
         WHERE ns.source = v_src AND ns.key IN (r.person_id || ':1', r.person_id || ':2') AND ns.state = 'fired';
        IF v_fired_at IS NOT NULL AND EXISTS (
               SELECT 1 FROM jsonb_array_elements(v_secs) s
                WHERE s->>'status' = 'unknown' AND (s->>'changed_at')::timestamptz > v_fired_at) THEN
            PERFORM core.fn_notify_resolve(v_src, r.person_id || ':1');
            PERFORM core.fn_notify_resolve(v_src, r.person_id || ':2');
        END IF;

        SELECT ns.state, ns.last_fired_at INTO v_s1_state, v_s1_at FROM core.notification_state ns
         WHERE ns.source = v_src AND ns.key = r.person_id || ':1';
        v_stage := NULL;
        IF v_idle >= interval '3 days' AND COALESCE(v_s1_state, 'ok') = 'ok' THEN
            IF core.fn_should_notify(v_src, r.person_id || ':1') THEN v_stage := 1; END IF;
        ELSIF v_idle >= interval '10 days' AND v_s1_state = 'fired' AND v_s1_at <= now() - interval '7 days' THEN
            IF core.fn_should_notify(v_src, r.person_id || ':2') THEN v_stage := 2; END IF;
        END IF;

        IF v_stage IS NOT NULL THEN
            v_out := v_out || jsonb_build_object('person_id', r.person_id, 'chat_id', v_chat, 'stage', v_stage,
                                                 'package', v_next->>'package', 'section_key', v_next->>'key');
        END IF;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'nudges', v_out);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_onboarding_nudges_due(jsonb) FROM public;
