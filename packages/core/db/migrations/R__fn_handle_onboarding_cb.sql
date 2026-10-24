-- ============================================================
-- core.fn_handle_onboarding_cb(p) — Registry-Handler des Callback-Prefix 'onboarding' (member_permeable)
--   Der MITGLIEDER-Pfad der /onboarding-Menue-Knoepfe: der Owner nimmt den hartkodierten 'Callback action'-Arm
--   im Orchestrator; ein aufgeloestes Mitglied kommt ueber core.fn_dispatch_callback (DB-Gesetz "Callback-Member-
--   Gate", member_permeable fail-closed) hierher. Der Handler entscheidet die FEINE Autorisierung und gibt bei
--   Erfolg {ok:true, route:'onboarding'} zurueck -> der Orchestrator routet in den bestehenden 'Onboarding section?'-
--   Switch (dessen Arme quittieren selbst); sonst {ok:false, toast} -> 'Answer dispatched cb'.
--   p: { data:'onboarding:<package>:<key>' | 'onboarding:_area:[<package>]', chat_id (from.id), chat_type }.
--   Regeln:
--     * nur Privatchat (chat_type='private'): in Gruppen waere die Agent-Identitaet (message.chat.id) nicht der Tapper;
--     * '_area:' (Uebersicht) bzw. '_area:<aktives Paket mit onboarding_state>' -> route;
--     * 'core:household' bzw. '<pkg>:<key>': Paket aus core.package_registry (aktiv, nie Caller-Text als Identifier),
--       <pkg>.onboarding_state per to_regclass (Suffix literal), section_key im Katalog (nur als USING-Parameter);
--       Nicht-Owner nur fuer persoenliche Pakete (core.fn_package_is_per_user) — core/Haushalt -> Toast;
--     * alles andere -> Toast 'Bereich nicht verfuegbar'. Nie RAISE (der Dispatcher-Vertrag).
--   Toasts aus dem Textkatalog (core.toast.*) in der Sprache des Tippenden (agent.fn_person_lang).
--   SECURITY INVOKER (laeuft unter der Host-Cred des Dispatchers, die agent/core/<pkg> liest), search_path gepinnt.
--   Tests: tests/db/core/test_fn_handle_onboarding_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_onboarding_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_part   text := split_part(v_data, ':', 2);
    v_key    text := split_part(v_data, ':', 3);
    v_chat   bigint;
    v_owner  boolean;
    v_pkg    text;
    v_rel    text;
    v_found  boolean;
    v_sender jsonb;
    v_lang   text;
    v_na     text;
BEGIN
    -- Tippenden zuerst aufloesen: Rolle (unten) + Toast-Sprache (Textkatalog §3.11, unaufgeloest -> Owner-Sprache).
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := agent.fn_resolve_sender(v_chat);
    v_owner  := (v_sender->>'role') IS NOT DISTINCT FROM 'owner';
    v_lang   := agent.fn_person_lang(v_sender->>'person_id')->>'lang';
    v_na     := core.fn_ui_text('core.toast.area_unavailable', v_lang);

    IF COALESCE(p->>'chat_type', '') <> 'private' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_private_chat',
            'toast', core.fn_ui_text('core.toast.onboarding_private_only', v_lang));
    END IF;
    -- Bereichs-Knoepfe: Uebersicht (leer) oder ein aktives Paket mit Onboarding-Tabelle.
    IF v_part = '_area' THEN
        IF v_key = '' THEN
            RETURN jsonb_build_object('ok', true, 'route', 'onboarding');
        END IF;
        SELECT r.package INTO v_pkg FROM core.package_registry r
        WHERE r.package = v_key AND r.status = 'active' AND r.package <> 'core';
        IF v_pkg IS NULL OR to_regclass(format('%I.onboarding_state', v_pkg)) IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'unknown_area', 'toast', v_na);
        END IF;
        RETURN jsonb_build_object('ok', true, 'route', 'onboarding');
    END IF;

    -- Ab hier zaehlt die Rolle (der Dispatcher hat den Sender schon als aufgeloest geprueft).
    -- Owner-Zweige sind Verteidigung in der Tiefe: heute nimmt der Owner den hartkodierten 'Callback action'-Arm.

    -- Core-Haushalt: nur der Owner.
    IF v_part = 'core' THEN
        IF v_key <> 'household' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'unknown_section', 'toast', v_na);
        END IF;
        IF NOT v_owner THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'owner_only',
                'toast', core.fn_ui_text('core.toast.owner_sets_up', v_lang));
        END IF;
        RETURN jsonb_build_object('ok', true, 'route', 'onboarding');
    END IF;

    -- Paket-Abschnitt: Paketname NUR aus der Registry, Tabelle per to_regclass, section_key nur als Parameter.
    SELECT r.package INTO v_pkg FROM core.package_registry r
    WHERE r.package = v_part AND r.status = 'active' AND r.package <> 'core';
    IF v_pkg IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_package', 'toast', v_na);
    END IF;
    v_rel := to_regclass(format('%I.onboarding_state', v_pkg))::text;
    IF v_rel IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_package', 'toast', v_na);
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE section_key = $1)', v_rel) USING v_key INTO v_found;
    IF NOT v_found THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_section', 'toast', v_na);
    END IF;
    IF NOT v_owner AND NOT core.fn_package_is_per_user(v_pkg) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only',
            'toast', core.fn_ui_text('core.toast.owner_sets_up', v_lang));
    END IF;
    RETURN jsonb_build_object('ok', true, 'route', 'onboarding');
END;
$$;
