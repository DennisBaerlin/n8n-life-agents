-- ============================================================
-- fn_delete_thinking_lease ("Bot denkt nach"-Schalter)
--   Beendet Draft-Schleifen: execution_id gesetzt -> genau dieser Schalter; sonst chat_id -> alle Schalter des Chats
--   (zweites Netz nach einer Antwort: 'Finish card lock' im Orchestrator).
--   wait_for_draft=true (direkt VOR einer Antwort): liegt drafting_until eines geloeschten Schalters noch in der
--   Zukunft, ist evtl. ein Draft unterwegs -> pg_sleep bis dahin (hoechstens 1 s), damit er VOR der Antwort ankommt.
--   Das pg_sleep laeuft nach dem DELETE in derselben Transaktion; die Zeilensperre bleibt dabei absichtlich bestehen,
--   so liefert ein gleichzeitiger fn_claim_thinking_draft danach 'stop'. Ohne das Flag (zweites Netz, Fehlerpfad
--   core.sub_error_notify) nie warten. Leere/unbekannte Angaben bzw. Test-Sentinel = no-op. Idempotent.
--   p: { execution_id? | chat_id?, wait_for_draft? }
--   RUECKGABE: {ok:true, removed}
--   Tests: tests/db/core/test_fn_thinking_lease.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_delete_thinking_lease(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_exec  text := NULLIF(trim(p->>'execution_id'), '');
    v_until timestamptz;
    v_n     int;
    v_wait  numeric;
BEGIN
    IF v_exec IS NOT NULL THEN
        WITH d AS (DELETE FROM agent.thinking_lease WHERE execution_id = v_exec RETURNING drafting_until)
        SELECT count(*), max(drafting_until) INTO v_n, v_until FROM d;
    ELSIF COALESCE(p->>'chat_id', '') ~ '^-?[0-9]+$' THEN
        WITH d AS (DELETE FROM agent.thinking_lease WHERE chat_id = (p->>'chat_id')::bigint RETURNING drafting_until)
        SELECT count(*), max(drafting_until) INTO v_n, v_until FROM d;
    ELSE
        RETURN jsonb_build_object('ok', true, 'removed', false);
    END IF;

    IF v_n > 0 AND v_until IS NOT NULL AND COALESCE(NULLIF(p->>'wait_for_draft', '')::boolean, false) THEN
        v_wait := LEAST(1.0, extract(epoch FROM v_until - clock_timestamp()));
        IF v_wait > 0 THEN
            PERFORM pg_sleep(v_wait);
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'removed', v_n > 0);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_delete_thinking_lease(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_delete_thinking_lease(JSONB) FROM context_ro;
    END IF;
END $$;
