-- ============================================================
-- core.fn_handle_plan_cb(p) — Registry-Handler des Callback-Prefix 'plan' (member_permeable)
--   Der Knopf des Onboarding-Plan-Schritts (plan:<domain>, aus core.sub_send_onboarding_menu: Fertig-Karte, Bereichs-
--   ansicht, Uebersicht). Owner und Mitglied kommen beide ueber core.fn_dispatch_callback hierher (kein hartkodierter
--   'Callback action'-Arm). Bei Erfolg {ok:true, route:'plan', domain} -> der Orchestrator ('Plan route?') startet den
--   advisor_agent der Domaene mit festem Auftrag; sonst {ok:false, reason, toast} -> 'Answer dispatched cb'.
--   p: { data:'plan:<domain>', chat_id (from.id), chat_type }.
--   Regeln (Entscheid allein aus core.fn_advisor_plan_status = die eine Adresse):
--     * nur Privatchat (die Agent-Identitaet message.chat.id muss der Tapper sein);
--     * <domain> = Zeile der Plan-Status-Liste (plan_step + Paket aktiv), nie Caller-Text als Identifier -> sonst
--       Toast 'nicht verfuegbar';
--     * can_write=false (Mitglied am Haushalts-Plan, write_permission owner_only) -> Toast "pflegt der Haushalts-Owner";
--     * ready=false (Mindestdaten fehlen, readiness_fn) -> Toast "fehlen noch Daten" (Schutz fuer alte Karten; das Menue
--       zeigt dann statt des Plan-Knopfs "Zuerst: <Abschnitt>").
--   Verben (share/explain/wish/resume und scan/event/alert/watch/drift/check sind als Domain-Name reserviert):
--     plan:resume:<domain>[:<plan_id>] -> [Weiter] der Beratungs-Erinnerung (core.fn_advisor_resume_due): laeuft durch den
--       Start (Domain, can_write, ready) plus offene Karte -> Toast plan_card_open; liegt ein Entwurf vor -> verb start (derselbe
--       Auftrag wie der Plan-Knopf, auch wenn die plan_id inzwischen eine andere ist: gewollt ist weitermachen, nicht eine
--       Version); kein Entwurf mehr -> Toast plan_not_current (reason stale).
--     plan:share:<domain>:<version> -> nur Owner, Version = aktive Version des Haushalts-Plans (sonst 'nicht aktuell')
--     plan:explain:<domain> | plan:wish:<domain> -> nur Rolle partner (Owner: Hinweis, Kind: nur Erwachsene), aktiver
--       Haushalts-Plan (core.fn_household_plan_active); persoenliche Plaene (career) -> nicht verfuegbar.
--     Rueckgabe {ok:true, route:'plan', verb: start|share|explain|wish, domain, version?, summary? (explain/wish)}.
--   Berater-Verben: plan:scan|event|alert|watch|drift|check:<domain>[:<version>] -> nur can_write (alert auf general: Owner); offene Karte, Doppeltipp
--     (Sperre 10 Minuten), Tageslimit advisor.button_starts_per_day (je Haushalt) und leere Daten -> Toast. Eine alte Version bekommt den Stale-Toast, ohne das Limit zu verbrauchen.
--     data nur aus festen Feldlisten (Art, Wert, Einheit, Datum, Domain), nie reason, action_note oder URL; event/alert/drift lesen nur, wenn die fn existiert.
--     check = [Jetzt pruefen] des Pruef-Schritts (ohne Version): data.entries = erledigter Altbestand ohne Provenienz aus
--     core.fn_handoff_register (row_kind legacy, status done), den der Pruef-Schritt angeboten hat (Merker <domain>:<who>:check:<id>)
--     und der noch nicht beim Berater war (Merker ...:checked:<id>, nach bestandener Sperre gesetzt: einmal je Aufgabe; sein
--     last_fired_at ist der Beginn der Wartezeit advisor.rollout_wait_days bis zum Ergebnis in core.fn_plan_rollout_next);
--     task_id, kind, text, section_key, topic, plan_text (Inhalt des Themas im aktiven Plan, ohne passendes Thema alle Themen des
--     Abschnitts, ohne Themen der Abschnittstext; hoechstens 600 Zeichen, NULL nur ohne Abschnitt im Plan); hoechstens 20; fuer den Auftrag "Eintrag pruefen".
--   Nie RAISE (Dispatcher-Vertrag). Toasts aus dem Textkatalog in der Sprache des Tippenden (agent.fn_person_lang).
--   SECURITY INVOKER (laeuft unter der Host-Cred des Dispatchers; die Plan-Status-fn ist DEFINER), search_path gepinnt.
--   Tests: tests/db/core/test_fn_handle_plan_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_plan_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_verb   text := split_part(v_data, ':', 2);
    v_domain text;
    v_ver    text;
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_sender jsonb;
    v_role   text;
    v_lang   text;
    v_row    jsonb;
    v_plan   record;
    v_cand   jsonb;
    v_out    jsonb;
    v_n      int;
    v_limit  int;
    v_slot   boolean := false;
    v_day    text;
    v_ck     text;
    v_own_pid text;
    v_active agent.advisor_plans%ROWTYPE;
    v_resume boolean := false;
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(v_chat::bigint);
    END IF;
    v_role := v_sender->>'role';
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';

    IF COALESCE(p->>'chat_type', '') <> 'private' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_private_chat',
            'toast', core.fn_ui_text('core.toast.plan_private_only', v_lang));
    END IF;

    -- [Weiter] der Beratungs-Erinnerung: auf das Start-Format umschreiben (dieselben Pruefungen wie der Plan-Knopf),
    -- danach nur offene Karte und "noch ein Entwurf da" zusaetzlich. Vor allen Verben, sonst laese der Start 'resume' als Domain.
    IF v_verb = 'resume' THEN
        v_domain := split_part(v_data, ':', 3);
        v_ver    := split_part(v_data, ':', 4);
        IF v_domain !~ '^[a-z][a-z0-9_]*$' OR split_part(v_data, ':', 5) <> '' OR (v_ver <> '' AND v_ver !~ '^[0-9]{1,9}$') THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'unknown_plan', 'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
        END IF;
        v_resume := true;
        v_verb   := v_domain;
        v_data   := 'plan:' || v_domain;
    END IF;

    IF v_verb IN ('scan', 'event', 'alert', 'watch', 'drift', 'check') THEN
        v_domain := split_part(v_data, ':', 3);
        v_ver    := split_part(v_data, ':', 4);
        IF v_chat !~ '^[0-9]{1,18}$' OR v_domain = '' OR split_part(v_data, ':', 5) <> '' OR (v_ver <> '' AND v_ver !~ '^[0-9]{1,9}$') THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'unknown_plan', 'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
        END IF;
        IF v_domain = 'general' AND v_verb = 'alert' THEN
            IF v_role IS DISTINCT FROM 'owner' THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'owner_only', 'toast', core.fn_ui_text('core.toast.plan_owner_only', v_lang));
            END IF;
        ELSE
            SELECT e INTO v_row FROM jsonb_array_elements(core.fn_advisor_plan_status(v_chat)) e WHERE e->>'domain' = v_domain;
            IF v_row IS NULL THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'unknown_plan', 'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
            END IF;
            IF (v_row->>'can_write')::boolean IS NOT TRUE THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'owner_only', 'toast', core.fn_ui_text('core.toast.plan_owner_only', v_lang));
            END IF;
        END IF;
        IF agent.fn_get_hitl_pending_state(v_chat::bigint) IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'card_open', 'toast', core.fn_ui_text('core.toast.plan_card_open', v_lang));
        END IF;
        v_own_pid := CASE WHEN COALESCE((SELECT cs.scope FROM core.context_scopes cs JOIN core.advisors a ON a.plan_context = cs.context_name WHERE a.domain = v_domain), 'household') = 'per_user'
                          THEN v_sender->>'person_id' END;
        SELECT * INTO v_active FROM agent.advisor_plans x WHERE x.domain = v_domain AND x.status = 'active' AND x.person_id IS NOT DISTINCT FROM v_own_pid;
        IF v_ver <> '' AND (v_active.id IS NULL OR v_active.version IS DISTINCT FROM v_ver::int) THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'stale', 'toast', core.fn_ui_text('core.toast.plan_not_current', v_lang));
        END IF;

        IF v_verb = 'scan' THEN
            IF v_active.id IS NOT NULL THEN v_out := '{}'::jsonb; END IF;
        ELSIF v_verb = 'watch' THEN
            v_cand := v_active.watch_candidates;
            IF v_active.id IS NOT NULL AND jsonb_array_length(COALESCE(v_cand, '[]'::jsonb)) > 0 THEN v_out := jsonb_build_object('candidates', v_cand); END IF;
        ELSIF v_verb = 'event' AND to_regprocedure('core.fn_plan_refs_open(text,text,boolean)') IS NOT NULL THEN
            EXECUTE 'SELECT COALESCE(jsonb_agg(jsonb_build_object(''kind'', r->''kind'', ''value'', r->''value'', ''unit'', r->''unit'', ''date'', r->''date'', ''domain'', $1)), ''[]''::jsonb) FROM (SELECT r FROM jsonb_array_elements(core.fn_plan_refs_open($1, $2, true)) r LIMIT 20) q'
              INTO v_cand USING v_domain, v_own_pid;
            IF jsonb_array_length(v_cand) > 0 THEN v_out := jsonb_build_object('refs', v_cand); END IF;
        ELSIF v_verb = 'alert' AND to_regprocedure('core.fn_monitor_recent_alerts(text,int)') IS NOT NULL THEN
            EXECUTE 'SELECT COALESCE(jsonb_agg(jsonb_build_object(''kind'', a->''kind'', ''value'', a->''value'', ''unit'', a->''unit'', ''date'', a->''date'', ''domain'', $1)), ''[]''::jsonb) FROM (SELECT a FROM jsonb_array_elements(core.fn_monitor_recent_alerts($1, 7)) a LIMIT 20) q'
              INTO v_cand USING v_domain;
            IF jsonb_array_length(v_cand) > 0 THEN v_out := jsonb_build_object('alerts', v_cand); END IF;
        ELSIF v_verb = 'check' AND v_active.id IS NOT NULL THEN
            -- nur feste Felder des Registers, nie wanted/diff/call (Daten fuer den Auftrag an den Berater); plan_text = was der
            -- gueltige Plan zum Thema sagt (Thema wie fn_advisor_save_section ohne Gross-/Kleinschreibung; ohne passendes Thema alle
            -- Themen des Abschnitts als "Thema: Text", ohne Themen der Abschnittstext): Altbestand hat kein Soll, ein Unterschied
            -- laesst sich nicht ableiten, der Berater vergleicht diesen Wortlaut mit den Daten statt das Plan-Dokument zu durchsuchen.
            SELECT jsonb_agg(jsonb_build_object('task_id', e->'task_id', 'kind', e->'kind', 'text', e->'text', 'section_key', e->'section_key', 'topic', e->'topic',
                       'plan_text', left(COALESCE(
                           (SELECT t->>'content' FROM jsonb_array_elements(sec.topics) t
                             WHERE lower(btrim(t->>'topic')) = lower(btrim(e->>'topic')) LIMIT 1),
                           (SELECT string_agg((t->>'topic') || ': ' || (t->>'content'), E'\n' ORDER BY i)
                              FROM jsonb_array_elements(sec.topics) WITH ORDINALITY AS x(t, i) WHERE jsonb_typeof(t) = 'object'),
                           sec.obj->>'content', sec.obj->>'legacy_content'), 600)) ORDER BY (e->>'task_id')::int)
              INTO v_cand
              FROM (SELECT e FROM jsonb_array_elements(core.fn_handoff_register(v_domain, v_chat)) e
                     WHERE e->>'row_kind' = 'legacy' AND e->>'status' = 'done'
                       AND core.fn_plan_rollout_latch(v_domain || ':' || COALESCE(v_own_pid, 'household') || ':check:' || (e->>'task_id')) = 'done'
                       AND core.fn_plan_rollout_latch(v_domain || ':' || COALESCE(v_own_pid, 'household') || ':checked:' || (e->>'task_id')) <> 'done'
                     ORDER BY (e->>'task_id')::int LIMIT 20) q
             CROSS JOIN LATERAL (SELECT z.o AS obj, CASE WHEN jsonb_typeof(z.o->'topics') = 'array' THEN z.o->'topics' ELSE '[]'::jsonb END AS topics
                                   FROM (SELECT CASE WHEN jsonb_typeof(v_active.interview_state->(q.e->>'section_key')) = 'object'
                                                     THEN v_active.interview_state->(q.e->>'section_key') ELSE '{}'::jsonb END AS o) z) sec;
            IF v_cand IS NOT NULL THEN v_out := jsonb_build_object('entries', v_cand); END IF;
        ELSIF v_verb = 'drift' AND to_regprocedure('core.fn_advisor_review_read(text,text,jsonb)') IS NOT NULL THEN
            EXECUTE 'SELECT COALESCE(jsonb_agg(jsonb_build_object(''metric_key'', a->''metric_key'', ''kind'', a->''kind'', ''label'', a->''label'', ''value'', a->''value'', ''target'', a->''target'', ''drift'', a->''drift'')), ''[]''::jsonb) FROM (SELECT a FROM jsonb_array_elements(core.fn_advisor_review_read($1, $2)->''alerts'') a LIMIT 20) q'
              INTO v_cand USING v_domain, v_sender->>'person_id';
            IF jsonb_array_length(v_cand) > 0 THEN v_out := jsonb_build_object('alerts', v_cand); END IF;
        END IF;
        IF v_out IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'nothing_new', 'toast', core.fn_ui_text('core.toast.plan_nothing_new', v_lang));
        END IF;

        IF NOT core.fn_should_notify('plan_verb', v_verb || ':' || v_domain || ':' || v_chat, interval '10 minutes') THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'busy', 'toast', core.fn_ui_text('core.toast.plan_verb_busy', v_lang));
        END IF;
        v_limit := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'button_starts_per_day'), '')::int, 3);
        v_day := to_char(core.fn_today(), 'YYYY-MM-DD');
        FOR v_n IN 1..v_limit LOOP
            IF core.fn_should_notify('plan_verb_day', v_n || ':' || v_day, interval '36 hours') THEN v_slot := true; EXIT; END IF;
        END LOOP;
        IF NOT v_slot THEN
            PERFORM core.fn_notify_resolve('plan_verb', v_verb || ':' || v_domain || ':' || v_chat);
            RETURN jsonb_build_object('ok', false, 'reason', 'limit', 'toast', core.fn_ui_text('core.toast.plan_verb_limit', v_lang));
        END IF;
        -- check: jede uebergebene Aufgabe geht genau einmal an den Berater (Merker erst nach Sperre und Tageslimit)
        IF v_verb = 'check' THEN
            FOR v_n IN SELECT (x->>'task_id')::int FROM jsonb_array_elements(v_out->'entries') x LOOP
                v_ck := v_domain || ':' || COALESCE(v_own_pid, 'household') || ':checked:' || v_n;
                PERFORM core.fn_should_notify('plan_rollout', v_ck, interval '30 minutes');
                PERFORM core.fn_notify_commit('plan_rollout', v_ck);
            END LOOP;
        END IF;
        RETURN jsonb_build_object('ok', true, 'route', 'plan', 'verb', v_verb, 'domain', v_domain, 'version', v_active.version, 'data', v_out);
    END IF;

    -- Plan teilen: Verb zuerst (share/explain/wish sind als Domain-Name reserviert), sonst Start-Format.
    IF v_verb IN ('share', 'explain', 'wish') THEN
        v_domain := split_part(v_data, ':', 3);
        v_ver    := split_part(v_data, ':', 4);
        IF v_data <> ('plan:' || v_verb || ':' || v_domain || (CASE WHEN v_verb = 'share' THEN ':' || v_ver ELSE '' END))
           OR (v_verb = 'share' AND v_ver !~ '^[0-9]{1,9}$') THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'unknown_plan',
                'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
        END IF;
        -- Domain mit Plan-Schritt + Haushalts-Scope (persoenliche Plaene werden nicht geteilt)?
        IF NOT core.fn_household_plan_domain(v_domain) THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'unknown_plan',
                'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
        END IF;
        SELECT * INTO v_plan FROM core.fn_household_plan_active(v_domain);
        IF v_verb = 'share' THEN
            IF v_role IS DISTINCT FROM 'owner' THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'owner_only',
                    'toast', core.fn_ui_text('core.toast.plan_owner_only', v_lang));
            END IF;
            IF v_plan IS NULL OR v_plan.version IS DISTINCT FROM v_ver::int THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'stale',
                    'toast', core.fn_ui_text('core.toast.plan_not_current', v_lang));
            END IF;
            RETURN jsonb_build_object('ok', true, 'route', 'plan', 'verb', 'share', 'domain', v_domain, 'version', v_plan.version);
        END IF;
        -- explain / wish: nur erwachsene Mitglieder (partner); der Owner kennt den Plan, Kinder nie.
        IF v_plan IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'no_active_plan',
                'toast', core.fn_ui_text('core.toast.plan_not_current', v_lang));
        END IF;
        IF v_role = 'owner' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'owner',
                'toast', core.fn_ui_text('core.toast.plan_explain_members', v_lang));
        END IF;
        IF v_role IS DISTINCT FROM 'partner' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'adults_only',
                'toast', core.fn_ui_text('core.toast.plan_adults_only', v_lang));
        END IF;
        -- summary = die gespeicherte Aenderungs-Zusammenfassung der aktiven Version (DB-Inhalt, nie callback_data) -> der
        -- Erklaer-Auftrag reicht sie dem Berater (finance_ro liest agent.advisor_plans nicht).
        RETURN jsonb_build_object('ok', true, 'route', 'plan', 'verb', v_verb, 'domain', v_domain,
            'version', v_plan.version, 'summary', left(COALESCE(v_plan.change_summary, ''), 1500));
    END IF;

    -- Start (plan:<domain>, Onboarding-Plan-Schritt): Entscheid aus core.fn_advisor_plan_status.
    v_domain := v_verb;
    SELECT e INTO v_row FROM jsonb_array_elements(core.fn_advisor_plan_status(v_chat)) e
    WHERE e->>'domain' = v_domain AND v_data = 'plan:' || v_domain;
    IF v_row IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_plan',
            'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
    END IF;
    IF (v_row->>'can_write')::boolean IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only',
            'toast', core.fn_ui_text('core.toast.plan_owner_only', v_lang));
    END IF;
    IF (v_row->>'ready')::boolean IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_ready',
            'toast', core.fn_ui_text('core.toast.plan_not_ready', v_lang));
    END IF;
    IF v_resume AND agent.fn_get_hitl_pending_state(v_chat::bigint) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'card_open', 'toast', core.fn_ui_text('core.toast.plan_card_open', v_lang));
    END IF;
    IF v_resume AND v_row->>'state' <> 'draft' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'stale', 'toast', core.fn_ui_text('core.toast.plan_not_current', v_lang));
    END IF;
    RETURN jsonb_build_object('ok', true, 'route', 'plan', 'verb', 'start', 'domain', v_row->>'domain');
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handle_plan_cb(jsonb) FROM public;
