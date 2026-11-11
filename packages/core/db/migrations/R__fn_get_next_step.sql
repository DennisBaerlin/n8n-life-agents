-- ============================================================
-- core.fn_get_next_step(p) — der EINE naechste Schritt einer Person (READ)
--   Die DB bestimmt, das Modell formuliert nur (Owner-Entscheid 2026-11-11). Leser: Orchestrator (Laufzeit-Flags + Knopf am
--   Sendepunkt), agent.guide (Prompt), core.fn_check_next_step_tap (veralteter Knopf), Fortschritts-/Menue-Subs.
--   Regel (gleich der Menue-Regel planTarget in core.sub_send_onboarding_menu):
--     1. Absender ueber agent.fn_resolve_sender; nicht gefunden -> kind none ohne Beispiel. Rolle NULL zaehlt als Mitglied.
--     2. Mitglied und Haushalt offen -> kind wait (sonst Kreis Menue <-> "erst Haushalt").
--     3. erster offener Abschnitt in p.order (danach nicht gelistete in Overview-Reihenfolge), nur aktive Pakete
--        (core.fn_onboarding_overview); Nicht-Owner nur per_user-Abschnitte mit Rolle in for_roles (NULL = alle).
--     4. nur Owner, kein Abschnitt offen: core.fn_advisor_plan_status (erst hier, sie ruft Paket-fns), Plaene in p.plan_order,
--        erster mit can_write und state <> complete: reif -> plan:<domain>; Mindestdaten fehlen -> erster fehlender
--        Abschnitt (state first); unbekannter Abschnitt -> onboarding:_area:<pkg>.
--     5. sonst kind none.
--   Eingabe p: { chat_id (Pflicht), order:["core:household","<pkg>:<key>",…], plan_order:["<domain>",…], smalltalk?, with_example? }
--     order/plan_order kommen build-time aus derselben Quelle wie das Menue (Get-OnboardingSectionOrder).
--     smalltalk = core.fn_smalltalk_kind der Nachricht: nur greeting/ping unterliegen den Vorschlags-Grenzen.
--   RUECKGABE jsonb { ok:true, kind:'section'|'plan'|'wait'|'none', package, key, domain, state, generation, callback,
--     data, label, button, example, offer, role, sees_household } — wirft nie.
--     callback = Ziel ohne Suffix; data = callback_data des Knopfs (Onboarding-Ziele mit ':next' fuer den Tipp-Check);
--     button NULL, wenn data laenger als 64 Byte ist (Telegram-Grenze). state: open (Abschnitt) bzw. none|draft|gaps (Plan)
--     bzw. first (Plan braucht zuerst einen Abschnitt). generation = Epoch der letzten Lage-Aenderung (Wiederholungs-Keys).
--     example = core.fn_get_next_step_example (nicht bei wait/unbekannt; sonst nur bei kind none, offer false oder p.with_example). offer = darf jetzt ein Vorschlag mit Knopf
--     kommen (Knopf vorhanden und Grenzen frei, nur lesend; gesetzt wird erst am Sendepunkt ueber core.fn_claim_next_step_offer).
--     sees_household = core.fn_app_sees_household (die eine Rollenfrage, Kinder sehen keine Haushaltsfinanzen).
--   Texte ueber core.fn_ui_text in agent.fn_person_lang. STABLE, SECURITY DEFINER (liest agent.*, Paket-Fortschritt, Plaene),
--   search_path gepinnt, Body schema-qualifiziert; EXECUTE an core_ro in util_create_core_ro.sql.
--   LANGUAGE plpgsql: ruft alphabetisch spaetere R__-fns.
--   Tests: tests/db/core/test_fn_get_next_step.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_get_next_step(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    c_point  constant text := U&'\+01F449' || ' ';
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_order  jsonb := CASE WHEN jsonb_typeof(p->'order') = 'array' THEN p->'order' ELSE '[]'::jsonb END;
    v_porder jsonb := CASE WHEN jsonb_typeof(p->'plan_order') = 'array' THEN p->'plan_order' ELSE '[]'::jsonb END;
    v_small  text := p->>'smalltalk';
    v_sender jsonb;
    v_pid    text;
    v_role   text;
    v_owner  boolean;
    v_lang   text;
    v_sees   boolean;
    v_ov     jsonb;
    v_sec    jsonb;
    v_plan   jsonb;
    v_miss   text;
    v_out    jsonb;
    v_keys   jsonb;
    v_ready  boolean;
    v_gen    bigint;
BEGIN
    IF v_chat !~ '^[0-9]{1,18}$' THEN
        RETURN jsonb_build_object('ok', true, 'kind', 'none', 'example', NULL, 'offer', false, 'role', NULL, 'sees_household', false);
    END IF;
    v_sender := agent.fn_resolve_sender(v_chat::bigint);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', true, 'kind', 'none', 'example', NULL, 'offer', false, 'role', NULL, 'sees_household', false);
    END IF;
    v_pid   := v_sender->>'person_id';
    v_role  := v_sender->>'role';
    v_owner := v_role IS NOT DISTINCT FROM 'owner';
    v_lang  := agent.fn_person_lang(v_pid)->>'lang';
    v_sees  := core.fn_app_sees_household(v_pid);
    v_ov    := core.fn_onboarding_overview(v_chat);

    -- Mitglied bei offenem Haushalt: nichts vorschlagen (der Owner richtet noch ein)
    IF NOT v_owner AND EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_ov->'sections', '[]'::jsonb)) s
                               WHERE s->>'package' = 'core' AND s->>'status' = 'unknown') THEN
        RETURN jsonb_build_object('ok', true, 'kind', 'wait', 'example', NULL, 'offer', false, 'role', v_role, 'sees_household', v_sees);
    END IF;

    -- erster offener, fuer den Betrachter erlaubter Abschnitt: zuerst in order-Reihenfolge, dann der Rest der Overview
    SELECT s INTO v_sec
    FROM jsonb_array_elements(COALESCE(v_ov->'sections', '[]'::jsonb)) WITH ORDINALITY AS t(s, i)
    LEFT JOIN jsonb_array_elements_text(v_order) WITH ORDINALITY AS o(k, oi) ON o.k = (s->>'package') || ':' || (s->>'key')
    WHERE s->>'status' = 'unknown'
      AND (v_owner OR (
            COALESCE((s->>'per_user')::boolean, false)
            AND (jsonb_typeof(s->'for_roles') IS DISTINCT FROM 'array' OR (v_role IS NOT NULL AND (s->'for_roles') ? v_role))))
    ORDER BY COALESCE(o.oi, 100000 + t.i)
    LIMIT 1;

    IF v_sec IS NOT NULL THEN
        v_out := jsonb_build_object('kind', 'section', 'package', v_sec->>'package', 'key', v_sec->>'key', 'state', 'open',
            'generation', COALESCE(floor(extract(epoch FROM (v_sec->>'changed_at')::timestamptz))::bigint, 0),
            'callback', 'onboarding:' || (v_sec->>'package') || ':' || (v_sec->>'key'),
            'label', core.fn_ui_text((v_sec->>'package') || '.onboarding.' || (v_sec->>'key'), v_lang));
        v_out := v_out || jsonb_build_object('data', (v_out->>'callback') || ':next',
            'button', c_point || core.fn_ui_text('core.onboarding.menu.btn_next', v_lang, jsonb_build_object('label', v_out->>'label')));
    ELSIF v_owner THEN
        SELECT pl INTO v_plan
        FROM jsonb_array_elements(core.fn_advisor_plan_status(v_chat)) pl
        LEFT JOIN jsonb_array_elements_text(v_porder) WITH ORDINALITY AS o(d, oi) ON o.d = pl->>'domain'
        WHERE (pl->>'can_write')::boolean AND pl->>'state' <> 'complete'
        ORDER BY COALESCE(o.oi, 100000), pl->>'domain'
        LIMIT 1;
        IF v_plan IS NOT NULL THEN
            SELECT COALESCE(floor(extract(epoch FROM max(ap.updated_at)))::bigint, 0) INTO v_gen
            FROM agent.advisor_plans ap
            WHERE ap.domain = v_plan->>'domain' AND (ap.person_id IS NULL OR ap.person_id = v_pid)
              AND ap.status IN ('draft', 'active');
            v_ready := COALESCE((v_plan->>'ready')::boolean, true) AND jsonb_array_length(COALESCE(v_plan->'missing', '[]'::jsonb)) = 0;
            IF v_ready THEN
                v_out := jsonb_build_object('kind', 'plan', 'package', v_plan->>'package', 'domain', v_plan->>'domain',
                    'state', v_plan->>'state', 'generation', v_gen, 'callback', 'plan:' || (v_plan->>'domain'),
                    'label', core.fn_ui_text((v_plan->>'package') || '.plan_step.btn_' || (v_plan->>'state'), v_lang,
                                             jsonb_build_object('open', COALESCE((v_plan->>'open')::int, 0))));
                v_out := v_out || jsonb_build_object('data', v_out->>'callback',
                    'button', c_point || core.fn_ui_text('core.onboarding.menu.btn_next', v_lang, jsonb_build_object('label', v_out->>'label')));
            ELSE
                v_miss := v_plan->'missing'->0->>'section';
                SELECT s INTO v_sec FROM jsonb_array_elements(COALESCE(v_ov->'sections', '[]'::jsonb)) s
                WHERE s->>'package' = v_plan->>'package' AND s->>'key' = v_miss;
                v_out := jsonb_build_object('kind', 'plan', 'package', v_plan->>'package', 'domain', v_plan->>'domain',
                    'state', 'first', 'generation', v_gen);
                IF v_sec IS NOT NULL THEN
                    v_out := v_out || jsonb_build_object('key', v_miss,
                        'callback', 'onboarding:' || (v_plan->>'package') || ':' || v_miss,
                        'label', core.fn_ui_text((v_plan->>'package') || '.onboarding.' || v_miss, v_lang));
                ELSE
                    v_out := v_out || jsonb_build_object('callback', 'onboarding:_area:' || (v_plan->>'package'),
                        'label', core.fn_ui_text((v_plan->>'package') || '.package.name', v_lang));
                END IF;
                v_out := v_out || jsonb_build_object('data', (v_out->>'callback') || ':next',
                    'button', c_point || core.fn_ui_text('core.onboarding.menu.btn_first', v_lang, jsonb_build_object('label', v_out->>'label')));
            END IF;
        END IF;
    END IF;

    IF v_out IS NULL THEN
        v_out := jsonb_build_object('kind', 'none');
    ELSIF octet_length(v_out->>'data') > 64 THEN
        v_out := v_out || jsonb_build_object('button', NULL);
    END IF;

    -- offer (nur lesend): Knopf vorhanden UND bei Gruss/Lebenszeichen beide Grenzen frei
    IF v_out->>'button' IS NULL THEN
        v_out := v_out || jsonb_build_object('offer', false);
    ELSIF v_small IS NULL OR v_small NOT IN ('greeting', 'ping') THEN
        v_out := v_out || jsonb_build_object('offer', true);
    ELSE
        v_keys := core.fn_next_step_offer_keys(v_pid, v_out->>'callback', v_out->>'state', (v_out->>'generation')::bigint);
        v_out := v_out || jsonb_build_object('offer',
            (jsonb_array_length(v_keys->'day') = 0
             OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_keys->'day') k WHERE NOT core.fn_notify_told('next_step_day', k)))
            AND (jsonb_array_length(v_keys->'repeat') = 0
             OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_keys->'repeat') k WHERE NOT core.fn_notify_told('next_step_offer', k))));
    END IF;

    -- Beispielfrage nur, wo sie gebraucht wird (kein Schritt, kein Knopf-Angebot, oder p.with_example): sie fragt je aktivem
    -- Paket eine fn und laeuft sonst bei jeder Nachricht mit.
    RETURN jsonb_build_object('ok', true, 'role', v_role, 'sees_household', v_sees,
                              'example', CASE WHEN v_out->>'kind' = 'none' OR (v_out->>'offer')::boolean IS NOT TRUE
                                                   OR COALESCE((p->>'with_example')::boolean, false)
                                              THEN core.fn_get_next_step_example(v_pid, v_order) END) || v_out;
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', true, 'kind', 'none', 'example', NULL, 'offer', false, 'role', NULL, 'sees_household', false);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_get_next_step(jsonb) FROM public;
-- EXECUTE fuer core_ro (Orchestrator, Guide, Menue lesen unter core_ro) erteilt packages/core/db/util/util_create_core_ro.sql.
