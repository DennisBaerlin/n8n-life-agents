-- ============================================================
-- core.fn_plan_rollout_lagging() (READ-ONLY — Chats fuer den taeglichen Nachzuegler-Lauf)
--   Chats mit aktivem Plan und moeglichem offenem Schritt: noch nicht durchgesehen, offene Aufgaben, Wert-Kandidaten oder Schluss nicht festgeschrieben.
--   Entscheidung und Claim bleiben in core.fn_plan_rollout_claim; hier nur die Vorauswahl.
--   RUECKGABE: {chats:[chat_id,...]}. Tests: tests/db/core/test_fn_plan_rollout_claim.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_rollout_lagging()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_owner text := agent.fn_owner_person_id();
BEGIN
    RETURN jsonb_build_object('chats', COALESCE((
        SELECT jsonb_agg(DISTINCT core.fn_person_chat_id(COALESCE(p.person_id, v_owner)))
          FROM agent.advisor_plans p
          JOIN core.advisors a ON a.domain = p.domain AND a.plan_step
         WHERE p.status = 'active'
           AND core.fn_person_chat_id(COALESCE(p.person_id, v_owner)) IS NOT NULL
           AND (p.synced_at IS NULL
                OR jsonb_array_length(p.watch_candidates) > 0
                OR EXISTS (SELECT 1 FROM agent.handoff_tasks t WHERE t.domain = p.domain AND t.status IN ('open', 'working'))
                OR core.fn_plan_rollout_latch(p.domain || ':' || COALESCE(p.person_id, 'household') || ':' || p.version || ':5') <> 'done')
    ), '[]'::jsonb));
END;
$$;
