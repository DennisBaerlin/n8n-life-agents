-- ============================================================
-- agent.fn_reject_learn_candidate(p jsonb) -> jsonb   (Phase C, WS-3)
--   Owner-gegateter Reject (Orchestrator-Callback learn:no:<id>): setzt einen PENDING-Kandidaten auf
--   'rejected'. DURABLE Rejection-Memory: rejected bleibt liegen (der TTL-Cleanup raeumt nur pending->expired),
--   und agent.fn_record_learn_candidates unterdrueckt denselben slot_key < learn_context.expiry_days erneut
--   vorzuschlagen -> "einmal abgelehnt, nicht wieder nerven". owner_only-Backstop.
--   Gelesene p-Keys: { candidate_id, chat_id }. INVOKER, search_path-Pin + REVOKE.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_reject_learn_candidate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog, agent, core
AS $$
DECLARE
    v_cid bigint := NULLIF(p->>'candidate_id', '')::bigint;
    v_n   int;
BEGIN
    IF agent.fn_sender_is_member(p->>'chat_id') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;
    IF v_cid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'candidate_id required');
    END IF;
    UPDATE agent.guide_learn_candidates SET status = 'rejected', rejected_at = now()
    WHERE id = v_cid AND status = 'pending';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'candidate not found or not pending');
    END IF;
    RETURN jsonb_build_object('ok', true, 'candidate_id', v_cid);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_reject_learn_candidate(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN REVOKE ALL ON FUNCTION agent.fn_reject_learn_candidate(jsonb) FROM context_ro; END IF;
END $$;
