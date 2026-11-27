-- ============================================================
-- core.fn_handoff_claim_ttl() — wie lange ein Claim einer vereinbarten Plan-Aufgabe als "diese Runde" gilt (READ)
--   Die eine Lese-Adresse fuer core.config advisor.handoff_claim_ttl_minutes (fehlend -> 120), in Minuten.
--   Aufrufer: core.fn_handoff_task_check, core.fn_handle_handoff_cb, core.fn_handoff_overview, core.fn_plan_rollout_next,
--   core.fn_stash_hitl_note.
--   Rueckgabe int. STABLE, INVOKER, search_path gepinnt; plpgsql (late-bound).
--   Tests: tests/db/core/test_fn_handoff_claim_ttl.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_claim_ttl()
RETURNS int
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
END;
$$;
