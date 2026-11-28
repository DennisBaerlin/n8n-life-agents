-- ============================================================
-- core.fn_handoff_claim_ttl() — wie lange ein Claim einer vereinbarten Plan-Aufgabe als "diese Runde" gilt (READ)
--   Die eine Lese-Adresse fuer core.config advisor.handoff_claim_ttl_minutes (fehlend oder unlesbar -> 120), in Minuten.
--   Aufrufer: core.fn_handoff_task_check, core.fn_handoff_status_now,
--   agent.fn_stash_hitl_note.
--   Rueckgabe int. STABLE, INVOKER, search_path gepinnt; plpgsql (late-bound).
--   Tests: tests/db/core/test_fn_handoff_claim_ttl.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_claim_ttl()
RETURNS int
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN COALESCE(substring(COALESCE(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '') FROM '^\s*(\d{1,6})\s*$')::int, 120);
END;
$$;

-- ============================================================
-- core.fn_handoff_status_now(p_status, p_claimed_at) — Stand einer vereinbarten Plan-Aufgabe, wie Nutzer und Berater ihn sehen (READ)
--   Die eine Regel "Claim abgelaufen": working mit claimed_at aelter als core.fn_handoff_claim_ttl() -> 'open' (der Lauf, der sie
--   beansprucht hat, ist abgebrochen; niemand arbeitet daran, sie wird wieder angeboten); jeder andere Stand unveraendert (done
--   bleibt done, keine Doppelbuchung). Gespeichert wird nichts: der Knopf beansprucht eine solche Aufgabe neu.
--   Aufrufer: core.fn_handle_handoff_cb (was der Knopf beanspruchen darf), core.fn_handoff_overview (was die Liste zeigt),
--   core.fn_plan_rollout_next (laufendes Durchgehen wartet still),
--   core.fn_advisor_open_handoffs (Status im Berater-Snapshot).
--   Rueckgabe text. STABLE, INVOKER, search_path gepinnt; plpgsql (late-bound).
--   Tests: tests/db/core/test_fn_advisor_open_handoffs.sql, tests/db/core/test_fn_handoff_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_status_now(p_status text, p_claimed_at timestamptz)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN CASE WHEN p_status = 'working' AND p_claimed_at < now() - make_interval(mins => core.fn_handoff_claim_ttl())
                THEN 'open' ELSE p_status END;
END;
$$;
