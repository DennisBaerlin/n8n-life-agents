-- ============================================================
-- agent.fn_set_hitl_pending_approved (Karte endgueltig bestaetigt, Bot mit Gesicht 2026-10-30)
--   Das HITL-Gate agent.tool_human_approval ruft sie NUR an seinen Erfolgs-Ausgaengen (Owner-/Co-Freigabe,
--   Info, Self) mit seiner eigenen Execution-id: ALLE Zeilen dieser Execution (Vier-Augen-Pfad = Mitglieds- und
--   Owner-Zeile) bekommen approved=true. Ablehnung, Timeout oder ein Mitglieds-Tipp mit spaeterer Owner-
--   Ablehnung erreichen sie nie -> approved bleibt NULL. Leser: agent.fn_claim_persona_sticker (Sticker 'top').
--   Fail-open wie die ganze Sperre: kein RAISE, ein Fehler kostet nur den Sticker.
--   p: {execution_id}
--   RUECKGABE: {ok:true, rows} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_set_hitl_pending_approved.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_hitl_pending_approved(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_ex   text := NULLIF(btrim(COALESCE(p->>'execution_id', '')), '');
    v_rows int;
BEGIN
    IF v_ex IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'missing_execution_id');
    END IF;
    UPDATE agent.hitl_pending SET approved = true WHERE execution_id = v_ex;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'rows', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_set_hitl_pending_approved(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_set_hitl_pending_approved(JSONB) FROM context_ro;
    END IF;
END $$;
