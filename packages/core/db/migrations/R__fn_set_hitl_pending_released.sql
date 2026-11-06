-- ============================================================
-- fn_set_hitl_pending_released (Karte-offen-Sperre, Fix C)
--   Das HITL-Gate ruft sie nach jedem sendAndWait (Tipp oder Timeout): released_at = now() und
--   expires_at auf hoechstens now() + grace. Die Sperre bleibt also noch kurz bestehen — die geparkte Kette
--   dahinter antwortet erst noch und schreibt ihr Chat-Gedaechtnis; der Orchestrator loescht die Zeile nach
--   seiner Antwort (fn_delete_hitl_pending). core.sub_error_notify ruft sie mit grace 0 fuer einen
--   gescheiterten Gate-Lauf (sofort frei). Betrifft NUR Zeilen dieser execution. Leere execution_id
--   (Error-Trigger ohne execution, z. B. Trigger-Fehler) = no-op; fehlende grace_minutes = Bau-Fehler -> RAISE.
--   p: { execution_id, grace_minutes }
--   RUECKGABE: {ok:true, released}  (released = es war eine Zeile dieser execution da)
--   Tests: tests/db/core/test_fn_hitl_pending.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_hitl_pending_released(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_exec  text := NULLIF(trim(p->>'execution_id'), '');
    v_grace int  := NULLIF(p->>'grace_minutes', '')::int;
    v_n     int;
BEGIN
    IF v_grace IS NULL OR v_grace < 0 THEN
        RAISE EXCEPTION 'fn_set_hitl_pending_released: grace_minutes must be a non-negative integer';
    END IF;
    IF v_exec IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'released', false);
    END IF;

    UPDATE agent.hitl_pending
       SET released_at = now(),
           expires_at  = GREATEST(opened_at + interval '1 microsecond',
                                  LEAST(expires_at, now() + make_interval(mins => v_grace)))
     WHERE execution_id = v_exec;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'released', v_n > 0);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_set_hitl_pending_released(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_set_hitl_pending_released(JSONB) FROM context_ro;
    END IF;
END $$;
