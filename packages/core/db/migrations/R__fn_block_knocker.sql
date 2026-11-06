-- ============================================================
-- fn_block_knocker (WS-5d — unbekannten Anklopfer sperren)
--   Owner-Aktion (Telegram-Button am Knock-Notify ODER `lifeagents household block <uid>`): legt eine
--   Sperr-Zeile in agent.access_blocks an. Idempotent (ON CONFLICT DO NOTHING -> zweites Sperren = no-op).
--   Beruehrt die Knock-Dedup (core.notification_state, source='knock') NIE -> eine nie-geklopfte uid
--   (CLI-Pfad) erzeugt KEINE synthetische Knock-Latch-Zeile (Sperrliste bleibt ehrlich; arch-challenge D2).
--   p: { telegram_user_id, reason? }
--   RUECKGABE: {ok:true, telegram_user_id, blocked:true} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_is_blocked.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_block_knocker(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_uid bigint;
BEGIN
    IF COALESCE(p->>'telegram_user_id', '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'telegram_user_id is required');
    END IF;
    BEGIN
        v_uid := (p->>'telegram_user_id')::bigint;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'telegram_user_id must be numeric');
    END;

    INSERT INTO agent.access_blocks (telegram_user_id, reason)
    VALUES (v_uid, NULLIF(trim(p->>'reason'), ''))
    ON CONFLICT (telegram_user_id) DO NOTHING;

    RETURN jsonb_build_object('ok', true, 'telegram_user_id', v_uid, 'blocked', true);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_block_knocker(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_block_knocker(JSONB) FROM context_ro;
    END IF;
END $$;
