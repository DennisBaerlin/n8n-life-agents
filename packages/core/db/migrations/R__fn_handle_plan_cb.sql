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
    v_domain text := split_part(v_data, ':', 2);
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_sender jsonb;
    v_lang   text;
    v_row    jsonb;
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(v_chat::bigint);
    END IF;
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';

    IF COALESCE(p->>'chat_type', '') <> 'private' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_private_chat',
            'toast', core.fn_ui_text('core.toast.plan_private_only', v_lang));
    END IF;

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
    RETURN jsonb_build_object('ok', true, 'route', 'plan', 'domain', v_row->>'domain');
END;
$$;

REVOKE ALL ON FUNCTION core.fn_handle_plan_cb(jsonb) FROM public;
