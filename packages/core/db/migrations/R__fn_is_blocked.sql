-- ============================================================
-- fn_is_blocked (read-only Guard, WS-5d)
--   Liefert true, wenn die numerische Telegram-Identitaet in agent.access_blocks gesperrt ist.
--   DIE eine Stelle, die der Sperr-Check ausdrueckt — konsumiert von fn_register_knock (keine
--   Owner-Notiz) UND fn_claim_/fn_consume_pairing_challenge (gesperrte uid pairt nicht).
--   NULL-uid -> false (kein Block). Laeuft als Caller (SECURITY INVOKER): die Pairing-/Knock-fns
--   sind invoker und rufen es unter der Haupt-Credential (Blanket-Grant deckt access_blocks).
--   RUECKGABE: boolean
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_is_blocked(p_uid bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT p_uid IS NOT NULL
       AND EXISTS (SELECT 1 FROM agent.access_blocks WHERE telegram_user_id = p_uid);
$$;

REVOKE ALL ON FUNCTION agent.fn_is_blocked(bigint) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_is_blocked(BIGINT) FROM context_ro;
    END IF;
END $$;
