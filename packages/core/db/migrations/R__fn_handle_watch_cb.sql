-- ============================================================
-- core.fn_handle_watch_cb(p) — Registry-Handler des Callback-Prefix 'watch' (owner-only)
--   watch:on:<domain>:<version> schaltet drift_check und plan_review ein. Ein Knopf einer alten Version bekommt den Stale-Toast,
--   damit er nicht gegen ein spaeteres Ausschalten wirkt. p: {data, chat_id}. Rueckgabe {ok, toast}. Nie RAISE.
--   Tests: tests/db/core/test_fn_handle_watch_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_watch_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_domain text := split_part(v_data, ':', 3);
    v_ver    text := split_part(v_data, ':', 4);
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_sender jsonb;
    v_lang   text;
    v_plan   record;
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN v_sender := agent.fn_resolve_sender(v_chat::bigint); END IF;
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';
    IF v_data <> 'watch:on:' || v_domain || ':' || v_ver OR v_ver !~ '^[0-9]{1,9}$' OR NOT core.fn_household_plan_domain(v_domain) THEN
        RETURN jsonb_build_object('ok', false, 'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
    END IF;
    IF (v_sender->>'role') IS DISTINCT FROM 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'toast', core.fn_ui_text('core.toast.plan_owner_only', v_lang));
    END IF;
    SELECT * INTO v_plan FROM core.fn_household_plan_active(v_domain);
    IF v_plan IS NULL OR v_plan.version IS DISTINCT FROM v_ver::int THEN
        RETURN jsonb_build_object('ok', false, 'toast', core.fn_ui_text('core.toast.plan_not_current', v_lang));
    END IF;
    PERFORM core.fn_set_cron_enable(jsonb_build_object('key', 'drift_check', 'enabled', true, 'chat_id', v_chat));
    PERFORM core.fn_set_cron_enable(jsonb_build_object('key', 'plan_review', 'enabled', true, 'chat_id', v_chat));
    RETURN jsonb_build_object('ok', true, 'toast', core.fn_ui_text('core.toast.watch_on', v_lang));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handle_watch_cb(jsonb) FROM public;
