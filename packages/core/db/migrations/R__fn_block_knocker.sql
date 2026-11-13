-- ============================================================
-- fn_block_knocker (unbekannten Anklopfer sperren)
--   Owner-Aktion (Telegram-Button am Knock-Notify oder `lifeagents household block <uid>`): legt eine
--   Sperr-Zeile in agent.access_blocks an. Idempotent (ON CONFLICT DO NOTHING -> zweites Sperren = no-op).
--   Beruehrt die Knock-Dedup (core.notification_state, source='knock') nie -> eine nie-geklopfte uid
--   (CLI-Pfad) erzeugt keine synthetische Knock-Latch-Zeile (Sperrliste bleibt ehrlich).
--   Eingabe p: { telegram_user_id (Pflicht, numerisch), reason? }
--   Rueckgabe: {ok:true, telegram_user_id, blocked:true} | {ok:false, reason}; reason = "telegram_user_id is
--   required" | "telegram_user_id must be numeric".
--   Seiteneffekt: INSERT in agent.access_blocks.
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
