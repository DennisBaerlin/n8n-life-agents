-- ============================================================
-- fn_set_bot_username (ATOMIC WRITE) — traegt den Telegram-Benutzernamen des Bots in core.config (telegram.bot_username) ein
--   Eingabe: p_name (Benutzername aus getMe, ohne @). Der Name folgt zwingend aus dem Bot-Token, darum ersetzt er auch
--   einen von Hand gesetzten Wert; der Update-Seed laesst ihn stehen (Wert ungleich Default, core.fn_config_seed).
--   Rueckgabe: {ok:true, changed} (false = Wert stimmte schon, kein Schreibvorgang);
--              {ok:false, code:'invalid_name'|'no_row'}.
--   Aufrufer: postgres-Superuser (provisioning/lib/deploy_workflows.sh _sync_bot_username).
--   Tests: tests/db/core/test_fn_set_bot_username.sql, tests/mock_telegram/bot_username_cases.sh
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_set_bot_username(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_n int;
BEGIN
    IF p_name IS NULL OR p_name !~ '^[A-Za-z0-9_]{5,32}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_name');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.config WHERE category = 'telegram' AND key = 'bot_username') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_row');
    END IF;
    UPDATE core.config SET value = p_name
     WHERE category = 'telegram' AND key = 'bot_username' AND value IS DISTINCT FROM p_name;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'changed', v_n > 0);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_set_bot_username(text) FROM public;
