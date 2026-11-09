-- ============================================================
-- core.fn_set_proactive_pause(p) (WRITE -- eine Person setzt oder beendet ihre Pause ungefragter Nachrichten)
--   p: { chat_id (vom Callback, nie LLM), enabled }. Person nur aus agent.fn_resolve_sender(chat_id).
--   enabled=true: Upsert until_date = core.fn_today() + general.proactive_pause_days (Default 14); false: Zeile weg.
--   Rueckgabe: {ok:true, enabled, until_date|null} | {ok:false, reason: invalid_input|unresolved_sender}. Nie RAISE (Callback-Pfad).
--   INVOKER: gerufen von core.fn_handle_reminder_cb unter der Host-Cred des Dispatchers.
--   Tests: tests/db/core/test_fn_reminder_prefs.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_set_proactive_pause(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat    bigint;
    v_enabled boolean;
    v_pid     text;
    v_days    int;
    v_until   date;
BEGIN
    BEGIN
        v_chat    := NULLIF(p->>'chat_id', '')::bigint;
        v_enabled := (p->>'enabled')::boolean;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_input');
    END;
    IF v_enabled IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_input'); END IF;
    v_pid := agent.fn_resolve_sender(v_chat)->>'person_id';
    IF v_pid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'unresolved_sender'); END IF;

    IF NOT v_enabled THEN
        DELETE FROM agent.reminder_pause WHERE person_id = v_pid;
        RETURN jsonb_build_object('ok', true, 'enabled', false, 'until_date', NULL);
    END IF;

    BEGIN
        v_days := core.fn_config_get('core', 'general', 'proactive_pause_days')::int;
    EXCEPTION WHEN OTHERS THEN v_days := NULL; END;
    v_until := core.fn_today() + GREATEST(COALESCE(v_days, 14), 1);
    INSERT INTO agent.reminder_pause (person_id, until_date, set_at) VALUES (v_pid, v_until, now())
    ON CONFLICT (person_id) DO UPDATE SET until_date = EXCLUDED.until_date, set_at = now();
    RETURN jsonb_build_object('ok', true, 'enabled', true, 'until_date', v_until);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_set_proactive_pause(jsonb) FROM public;
