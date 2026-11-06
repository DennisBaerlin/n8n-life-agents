-- ============================================================
-- fn_claim_thinking_draft ("Bot denkt nach"-Schalter)
--   core.sub_show_thinking fragt sie VOR jedem Draft. Reihenfolge fest:
--     1. keine/abgelaufene Zeile bzw. keine execution_id  -> 'stop' (auch bei offener Karte)
--     2. offene Bestaetigungskarte im Chat der Zeile       -> 'pause' (keine Punkte ueber der Karte); verlaengert
--        (agent.hitl_pending: released_at NULL, nicht abgelaufen)   expires_at auf mind. now()+5 min (begrenzt,
--                                                            weil auch die Karte ablaeuft) -> nach dem Tipp weiter
--     3. sonst                                            -> 'show' und drafting_until = clock_timestamp()+1 s
--   SPERR-REIHENFOLGE (READ COMMITTED, jedes Statement eigener Snapshot): ZUERST die eigene Zeile FOR UPDATE, DANN
--   die Karte pruefen. fn_delete_thinking_lease und fn_create_hitl_pending sperren dieselbe Zeile:
--     - sperrt der Claim zuerst, sehen sie danach drafting_until und warten das Fenster ab (Draft landet VOR der
--       Antwort bzw. Karte);
--     - sperren sie zuerst, findet der Claim danach keine Zeile ('stop') bzw. sieht die Karte ('pause').
--   Nie Karte-pruefen-dann-sperren (dazwischen koennte die Karte committen).
--   p: { execution_id }
--   RUECKGABE: {ok:true, state: 'show'|'pause'|'stop'}
--   Tests: tests/db/core/test_fn_thinking_lease.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_claim_thinking_draft(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_exec text := NULLIF(trim(p->>'execution_id'), '');
    v_chat bigint;
BEGIN
    IF v_exec IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'state', 'stop');
    END IF;

    SELECT chat_id INTO v_chat FROM agent.thinking_lease
     WHERE execution_id = v_exec AND expires_at > now()
       FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', true, 'state', 'stop');
    END IF;

    IF EXISTS (SELECT 1 FROM agent.hitl_pending
                WHERE chat_id = v_chat AND released_at IS NULL AND expires_at > now()) THEN
        UPDATE agent.thinking_lease SET expires_at = GREATEST(expires_at, now() + interval '5 minutes')
         WHERE execution_id = v_exec;
        RETURN jsonb_build_object('ok', true, 'state', 'pause');
    END IF;

    UPDATE agent.thinking_lease SET drafting_until = clock_timestamp() + interval '1 second'
     WHERE execution_id = v_exec;
    RETURN jsonb_build_object('ok', true, 'state', 'show');
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_claim_thinking_draft(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_claim_thinking_draft(JSONB) FROM context_ro;
    END IF;
END $$;
