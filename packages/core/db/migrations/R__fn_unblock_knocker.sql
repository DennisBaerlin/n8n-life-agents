-- ============================================================
-- fn_unblock_knocker (WS-5d — Sperre aufheben)
--   Owner-Aktion (Telegram-„Entsperren"-Button ODER `lifeagents household unblock <uid>`): entfernt die
--   Sperr-Zeile aus agent.access_blocks. Idempotent (keine Zeile -> was_blocked:false). Beruehrt
--   die Knock-Dedup (core.notification_state, source='knock') NIE.
--   p: { telegram_user_id }
--   RUECKGABE: {ok:true, telegram_user_id, was_blocked:bool} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_is_blocked.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_unblock_knocker(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_uid bigint;
    v_del int;
BEGIN
    IF COALESCE(p->>'telegram_user_id', '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'telegram_user_id is required');
    END IF;
    BEGIN
        v_uid := (p->>'telegram_user_id')::bigint;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'telegram_user_id must be numeric');
    END;

    DELETE FROM agent.access_blocks WHERE telegram_user_id = v_uid;
    GET DIAGNOSTICS v_del = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'telegram_user_id', v_uid, 'was_blocked', v_del > 0);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_unblock_knocker(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_unblock_knocker(JSONB) FROM context_ro;
    END IF;
END $$;
