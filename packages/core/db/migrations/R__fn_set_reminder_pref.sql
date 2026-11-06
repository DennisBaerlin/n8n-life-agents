-- ============================================================
-- core.fn_set_reminder_pref(p) — eine Person schaltet IHRE Zustellung eines Person-Reminders (Roter Faden 2026-10-23)
--   p: { chat_id (vom Callback, nie LLM), key, enabled }
--   - Person NUR aus agent.fn_resolve_sender(chat_id); unaufgeloest -> {ok:false, reason:'unresolved_sender'}.
--   - key muss in core.cron_labels mit scope='person' stehen; Haushalts-Keys schaltet der Owner ueber
--     core.fn_set_cron_enable -> {ok:false, reason:'not_person_scoped'}; unbekannt -> {ok:false, reason:'unknown_key'}.
--   - Upsert in agent.reminder_prefs (idempotent).
--   RUECKGABE: {ok:true, key, enabled, person_id} | {ok:false, reason}. Nie RAISE (Callback-Pfad).
--   INVOKER: gerufen von core.fn_handle_reminder_cb unter der Host-Cred des Dispatchers. search_path gepinnt.
--   Tests: tests/db/core/test_fn_reminder_prefs.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_set_reminder_pref(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_key     text := COALESCE(p->>'key', '');
    v_chat    bigint;
    v_pid     text;
    v_scope   text;
    v_enabled boolean;
BEGIN
    BEGIN
        v_chat    := NULLIF(p->>'chat_id', '')::bigint;
        v_enabled := (p->>'enabled')::boolean;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid chat_id or enabled');
    END;
    IF v_enabled IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'enabled must be true|false');
    END IF;
    v_pid := agent.fn_resolve_sender(v_chat)->>'person_id';
    IF v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unresolved_sender');
    END IF;
    SELECT scope INTO v_scope FROM core.cron_labels WHERE cron_key = v_key;
    IF v_scope IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_key');
    END IF;
    IF v_scope <> 'person' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_person_scoped');
    END IF;

    INSERT INTO agent.reminder_prefs (person_id, cron_key, enabled, updated_at)
    VALUES (v_pid, v_key, v_enabled, now())
    ON CONFLICT (person_id, cron_key) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now();

    RETURN jsonb_build_object('ok', true, 'key', v_key, 'enabled', v_enabled, 'person_id', v_pid);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_set_reminder_pref(jsonb) FROM public;
