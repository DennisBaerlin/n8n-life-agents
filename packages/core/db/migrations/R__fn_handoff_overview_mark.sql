-- ============================================================
-- core.fn_handoff_overview_mark(p) — merkt die erfolgreich gesendete Uebergabe-Liste fuer die Abfolge
--   Gerufen von agent.tool_send_handoff_overview nach dem Send, damit Schritt 1 sie im selben Lauf nicht noch einmal schickt.
--   p: {domain, chat_id, max_task_id}. Schluessel wie core.fn_plan_rollout_next. RUECKGABE {ok, marked}. Nie RAISE.
--   Tests: tests/db/core/test_fn_handoff_overview_mark.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_overview_mark(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain text := COALESCE(p->>'domain', '');
    v_max    text := COALESCE(p->>'max_task_id', '');
    v_scope  text;
    v_who    text;
    v_key    text;
BEGIN
    IF v_domain = '' OR v_max !~ '^[0-9]+$' THEN RETURN '{"ok":true,"marked":false}'::jsonb; END IF;
    v_scope := COALESCE((SELECT cs.scope FROM core.context_scopes cs JOIN core.advisors a ON a.plan_context = cs.context_name WHERE a.domain = v_domain), 'household');
    v_who := CASE WHEN v_scope = 'per_user' THEN core.fn_handoff_person(p->>'chat_id') ELSE 'household' END;
    IF v_who IS NULL THEN RETURN '{"ok":true,"marked":false}'::jsonb; END IF;
    v_key := v_domain || ':' || v_who || ':handoff:' || v_max;
    PERFORM core.fn_should_notify('plan_rollout', v_key, NULL);
    PERFORM core.fn_notify_commit('plan_rollout', v_key);
    RETURN '{"ok":true,"marked":true}'::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN '{"ok":true,"marked":false}'::jsonb;
END;
$$;
