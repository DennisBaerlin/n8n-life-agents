-- ============================================================
-- core.fn_advisor_hot_since() — ab wann ein Berater-Entwurf als laufendes Plan-Gespraech gilt (READ)
--   Die eine Regel "das Plan-Gespraech laeuft gerade": ein Entwurf (agent.advisor_plans status draft), dessen updated_at
--   nach dem gelieferten Zeitpunkt liegt; aelter = pausiert. Rueckgabe now() - advisor.draft_hot_minutes (core.config,
--   Rueckfall 120 ohne Zeile; gelesen wie advisor.rollout_draft_stale_days). Gilt auch fuer die offene Frage eines Chats (agent.chat_prompts), die
--   wie ein laufendes Gespraech das Routing haelt.
--   Konsumenten: core.fn_advisor_pins, core.fn_advisor_hint_prompt, core.fn_advisor_hint_state, core.fn_plan_rollout_claim.
--   plpgsql STABLE INVOKER (core.fn_config_get liegt alphabetisch spaeter), search_path gepinnt.
--   Tests: tests/db/core/test_fn_advisor_pins.sql, tests/db/finance/test_fn_advisor_hints.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_hot_since()
RETURNS timestamptz
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN now() - make_interval(mins => COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'draft_hot_minutes'), '')::int, 120));
END;
$$;
