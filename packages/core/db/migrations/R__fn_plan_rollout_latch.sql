-- ============================================================
-- fn_plan_rollout_latch (READ-ONLY) — Zustand eines Rollout-Schritts
--   Eingabe: p_key text (notification_state-Key unter source 'plan_rollout'). Rueckgabe: text:
--   'free' = kein gueltiger Merker, 'pending' = beansprucht (Frist laeuft, ein anderer Lauf sendet gerade), 'done' = festgeschrieben.
--   Tests: tests/db/core/test_fn_plan_rollout_next.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_rollout_latch(p_key text)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE((
        SELECT CASE WHEN n.state <> 'fired' THEN 'free'
                    WHEN n.expires_at IS NULL THEN 'done'
                    WHEN n.expires_at > now() THEN 'pending'
                    ELSE 'free' END
          FROM core.notification_state n
         WHERE n.source = 'plan_rollout' AND n.key = p_key), 'free');
$$;
