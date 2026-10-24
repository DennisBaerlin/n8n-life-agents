-- ============================================================
-- core.fn_handle_reminder_cb(p) — Registry-Handler des Callback-Prefix 'rem' (member_permeable; Roter Faden 2026-10-23)
--   callback_data 'rem:on|off:<key>[:m]' — EIN Schalt-Weg fuer alle Erinnerungen (Karten-Knopf und /reminders-Menue):
--     * scope='person'    -> die TIPPENDE Person schaltet IHRE Zustellung (core.fn_set_reminder_pref, agent.reminder_prefs);
--     * scope='household' -> nur der Owner, ueber den Haushalts-Schalter core.fn_set_cron_enable (cron_enable.<key>);
--                            ein Mitglied bekommt den Toast core.toast.owner_only;
--     * mandatory         -> nie schaltbar (Pflicht-Erinnerung, z. B. Fristen im Ereignisfall): Toast core.toast.reminder_mandatory;
--     * unbekannt/kaputt  -> Toast core.toast.reminder_unavailable.
--   Suffix ':m' = Knopf aus dem /reminders-Menue -> Rueckgabe route:'reminders' (der Orchestrator sendet das Menue mit dem
--   neuen Stand neu); ohne Suffix (Karten-Knopf, z. B. [Nicht mehr erinnern]) nur der Toast.
--   Erreicht ueber core.fn_dispatch_callback (Member-Gate re-resolvt den Sender, member_permeable=true); der Owner
--   kommt ueber denselben generischen Dispatch (rem ist kein hartkodierter Orchestrator-Arm).
--   p: { data, chat_id (from.id), chat_type }
--   Toast in der Sprache des Tippenden: <pkg>.cron.<key>.on_toast|off_toast (Paket aus core.cron_labels). Nie RAISE.
--   SECURITY INVOKER (Host-Cred des Dispatchers, die core.config + agent.* schreibt), search_path gepinnt.
--   Tests: tests/db/core/test_fn_reminder_prefs.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_reminder_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_verb   text := split_part(v_data, ':', 2);
    v_key    text := split_part(v_data, ':', 3);
    v_menu   boolean := split_part(v_data, ':', 4) = 'm';
    v_chat   bigint;
    v_sender jsonb;
    v_lang   text;
    v_row    core.cron_labels%ROWTYPE;
    v_r      jsonb;
BEGIN
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := agent.fn_resolve_sender(v_chat);
    v_lang   := agent.fn_person_lang(v_sender->>'person_id')->>'lang';

    IF v_verb NOT IN ('on', 'off') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_verb',
            'toast', core.fn_ui_text('core.toast.reminder_unavailable', v_lang));
    END IF;
    SELECT * INTO v_row FROM core.cron_labels WHERE cron_key = v_key;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_key',
            'toast', core.fn_ui_text('core.toast.reminder_unavailable', v_lang));
    END IF;
    IF v_row.mandatory THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'mandatory',
            'toast', core.fn_ui_text('core.toast.reminder_mandatory', v_lang));
    END IF;

    IF v_row.scope = 'household' THEN
        IF (v_sender->>'role') IS DISTINCT FROM 'owner' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'owner_only',
                'toast', core.fn_ui_text('core.toast.owner_only', v_lang));
        END IF;
        v_r := core.fn_set_cron_enable(jsonb_build_object('key', v_key, 'enabled', v_verb = 'on'));
    ELSE
        v_r := core.fn_set_reminder_pref(jsonb_build_object('chat_id', p->>'chat_id', 'key', v_key, 'enabled', v_verb = 'on'));
    END IF;
    IF COALESCE((v_r->>'ok')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_r->>'reason',
            'toast', core.fn_ui_text('core.toast.reminder_unavailable', v_lang));
    END IF;

    RETURN jsonb_build_object('ok', true, 'key', v_key, 'enabled', v_verb = 'on',
        'toast', core.fn_ui_text(format('%s.cron.%s.%s_toast', v_row.package, v_key, v_verb), v_lang))
        || CASE WHEN v_menu THEN jsonb_build_object('route', 'reminders') ELSE '{}'::jsonb END;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_handle_reminder_cb(jsonb) FROM public;
