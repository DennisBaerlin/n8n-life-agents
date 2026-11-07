-- ============================================================
-- core.fn_handoff_overview(p) — offene vereinbarte Plan-Aufgaben einer Person fuer die Uebersicht [Durchgehen]
--   p: { domain (Pflicht, Plan-Domain), chat_id (Identitaet, core.fn_handoff_person) }.
--   Rueckgabe {count, max_task_id (NULL ohne offene), items: [text, ...] in Anlage-Reihenfolge}. Der Knopf traegt
--   handoff:<domain>:<max_task_id> -> core.fn_handle_handoff_cb beansprucht nur bis dahin (eine spaeter vereinbarte
--   Aufgabe kommt in die naechste Uebersicht). Es zaehlen open und working mit abgelaufenem Claim (advisor.handoff_claim_
--   ttl_minutes, dieselbe Regel wie der Claim in core.fn_handle_handoff_cb: ein abgebrochener Lauf darf nichts verstecken).
--   Nur lesend; aufgerufen von agent.tool_send_handoff_overview (Host-Cred). Tests: tests/db/core/test_fn_handoff_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_overview(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pid text := core.fn_handoff_person(p->>'chat_id');
    v_out jsonb;
    v_ttl int := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
BEGIN
    SELECT jsonb_build_object('count', count(*), 'max_task_id', max(t.id),
                              'items', COALESCE(jsonb_agg(t.text ORDER BY t.id), '[]'::jsonb))
      INTO v_out
      FROM agent.handoff_tasks t
     WHERE t.domain = COALESCE(p->>'domain', '') AND t.person_id = v_pid
       AND (t.status = 'open' OR (t.status = 'working' AND t.claimed_at < now() - make_interval(mins => v_ttl)));
    RETURN v_out;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_overview(jsonb) FROM public;
