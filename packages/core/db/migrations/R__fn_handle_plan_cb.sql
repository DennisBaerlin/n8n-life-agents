-- ============================================================
-- core.fn_handle_plan_cb(p) — Registry-Handler des Callback-Prefix 'plan' (member_permeable, 2026-10-28)
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
--   Verben (Plan teilen, 2026-10-28; share/explain/wish sind als Domain-Name reserviert):
--     plan:share:<domain>:<version> -> nur Owner, Version = aktive Version des Haushalts-Plans (sonst 'nicht aktuell')
--     plan:explain:<domain> | plan:wish:<domain> -> nur Rolle partner (Owner: Hinweis, Kind: nur Erwachsene), aktiver
--       Haushalts-Plan (core.fn_household_plan_active); persoenliche Plaene (career) -> nicht verfuegbar.
--     Rueckgabe {ok:true, route:'plan', verb: start|share|explain|wish, domain, version?, summary? (explain/wish)}.
--   Nie RAISE (Dispatcher-Vertrag). Toasts aus dem Textkatalog in der Sprache des Tippenden (agent.fn_person_lang).
--   SECURITY INVOKER (laeuft unter der Host-Cred des Dispatchers; die Plan-Status-fn ist DEFINER), search_path gepinnt.
--   Tests: tests/db/core/test_fn_handle_plan_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_plan_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
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

    -- Plan teilen (2026-10-28): Verb zuerst (share/explain/wish sind als Domain-Name reserviert), sonst Start-Format.
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
    RETURN jsonb_build_object('ok', true, 'route', 'plan', 'verb', 'start', 'domain', v_row->>'domain');
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handle_plan_cb(jsonb) FROM public;
