-- ============================================================
-- core.fn_handoff_overview(p) — offene vereinbarte Plan-Aufgaben einer Person fuer die Uebersicht [Durchgehen]
--   p: { domain (Pflicht, Plan-Domain), chat_id (Identitaet, core.fn_handoff_person), via (optional: 'rollout' =
--   Erinnerung der gefuehrten Abfolge, sonst der Berater) }.
--   Rueckgabe {count, max_task_id (NULL ohne offene), items: [text, ...] in Anlage-Reihenfolge, msg: Text-Struktur
--   core.handoff.overview (core.fn_ui_tpl) mit list (nummeriert), since (Tag des aeltesten offenen Punkts per
--   core.fn_today: heute -> core.handoff.since_today, sonst core.fn_ui_date; "offen seit", kein Gespraechsdatum: Punkte
--   aus mehreren Gespraechen und neu gespeicherte Abschnitte haetten sonst ein falsches) und why (warum die Liste jetzt
--   kommt, je via)}. Eine Adresse fuer beide Sender: agent.tool_send_handoff_overview und Schritt 1 von
--   core.fn_plan_rollout_next. Der Knopf traegt
--   handoff:<domain>:<max_task_id> -> core.fn_handle_handoff_cb beansprucht nur bis dahin (eine spaeter vereinbarte
--   Aufgabe kommt in die naechste Uebersicht). Es zaehlen open und working mit abgelaufenem Claim (advisor.handoff_claim_
--   ttl_minutes, dieselbe Regel wie der Claim in core.fn_handle_handoff_cb: ein abgebrochener Lauf darf nichts verstecken).
--   Nur lesend, Host-Cred. Tests: tests/db/core/test_fn_handoff_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_overview(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pid   text := core.fn_handoff_person(p->>'chat_id');
    v_out   jsonb;
    v_since date;
    v_ttl   int := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
BEGIN
    SELECT jsonb_build_object('count', count(*), 'max_task_id', max(t.id),
                              'items', COALESCE(jsonb_agg(t.text ORDER BY t.id), '[]'::jsonb)),
           core.fn_today(min(t.created_at))
      INTO v_out, v_since
      FROM agent.handoff_tasks t
     WHERE t.domain = COALESCE(p->>'domain', '') AND t.person_id = v_pid
       AND (t.status = 'open' OR (t.status = 'working' AND t.claimed_at < now() - make_interval(mins => v_ttl)));
    RETURN v_out || jsonb_build_object('msg', core.fn_ui_tpl('core.handoff.overview', jsonb_build_object(
        'list', (SELECT string_agg(i || '. ' || (x #>> '{}'), E'\n' ORDER BY i) FROM jsonb_array_elements(v_out->'items') WITH ORDINALITY AS e(x, i)),
        'since', CASE WHEN v_since IS NULL OR v_since >= core.fn_today() THEN core.fn_ui_tpl('core.handoff.since_today') ELSE core.fn_ui_date(v_since) END,
        'why', CASE WHEN p->>'via' = 'rollout' THEN core.fn_ui_tpl('core.handoff.why_rollout') ELSE core.fn_ui_tpl('core.handoff.why_advisor') END)));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_overview(jsonb) FROM public;
