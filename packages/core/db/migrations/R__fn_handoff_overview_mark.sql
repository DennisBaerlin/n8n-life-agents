-- ============================================================
-- core.fn_handoff_overview_mark(p) — merkt die erfolgreich gesendete Uebergabe-Liste fuer die Abfolge
--   Gerufen von agent.tool_send_handoff_overview nach dem Send, damit Schritt 1 sie im selben Lauf nicht noch einmal schickt.
--   p: {domain, chat_id, max_task_id}. Schluessel aus core.fn_handoff_latch_key (traegt die Version des gueltigen Plans: eine
--   Liste mitten im Entwurf haelt die Liste nach dem Veroeffentlichen nicht zurueck). Schreibt den Merker in
--   core.notification_state (source plan_rollout, ohne Frist, festgeschrieben ueber fn_should_notify + fn_notify_commit).
--   Rueckgabe {ok, marked}. Nie RAISE.
--   Tests: tests/db/core/test_fn_handoff_overview_mark.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_overview_mark(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_max text := COALESCE(p->>'max_task_id', '');
    v_key text;
BEGIN
    IF v_max !~ '^[0-9]{1,9}$' THEN RETURN '{"ok":true,"marked":false}'::jsonb; END IF;
    v_key := core.fn_handoff_latch_key(p->>'domain', p->>'chat_id', v_max::int);
    IF v_key IS NULL THEN RETURN '{"ok":true,"marked":false}'::jsonb; END IF;
    PERFORM core.fn_should_notify('plan_rollout', v_key, NULL);
    PERFORM core.fn_notify_commit('plan_rollout', v_key);
    RETURN '{"ok":true,"marked":true}'::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN '{"ok":true,"marked":false}'::jsonb;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_overview_mark(jsonb) FROM public;
