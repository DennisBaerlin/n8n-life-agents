-- ============================================================
-- core.fn_plan_rollout_claim(p) — Eingang der geführten Abfolge je Chat (Laufende, Nachzuegler)
--   p: {chat_id, budget ('true' nur vom taeglichen Nachzuegler: Slot 'plan_rollout' normal, erst wenn eine Nachricht feststeht; ohne Platz werden ihre Merker freigegeben)}. Guenstige Pruefungen zuerst: Chat numerisch, Schalter cron_enable.plan_rollout (core.fn_reminder_allowed), Sender aufgeloest, keine
--   offene Karte (released_at IS NULL, expires_at in der Zukunft), kein Entwurf der letzten 2 Stunden (Bedingung wie der Interview-Pin des Orchestrators).
--   Dann je Domain mit plan_step die erste nicht leere Antwort von core.fn_plan_rollout_next; ein Verlierer des Claims stoppt.
--   Nie core.fn_advisor_plan_status (ruft teure gaps_fn). Nie RAISE: Fehler -> leer.
--   Rueckgabe {messages:[...mit chat_id], step, domain}. INVOKER, search_path gepinnt. Tests: tests/db/core/test_fn_plan_rollout_claim.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_rollout_claim(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_empty  CONSTANT jsonb := '{"messages":[]}'::jsonb;
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_sender jsonb;
    v_pid    text;
    v_dom    text;
    v_res    jsonb;
BEGIN
    IF v_chat !~ '^[0-9]{1,18}$' THEN RETURN v_empty; END IF;
    v_sender := agent.fn_resolve_sender(v_chat::bigint);
    v_pid := v_sender->>'person_id';
    IF v_pid IS NULL THEN RETURN v_empty; END IF;
    IF NOT core.fn_reminder_allowed('plan_rollout', v_pid) THEN RETURN v_empty; END IF;
    IF EXISTS (SELECT 1 FROM agent.hitl_pending h WHERE h.chat_id = v_chat::bigint AND h.released_at IS NULL AND h.expires_at > now()) THEN RETURN v_empty; END IF;
    IF EXISTS (SELECT 1 FROM agent.advisor_plans d WHERE d.status = 'draft' AND d.updated_at > now() - interval '2 hours') THEN RETURN v_empty; END IF;

    FOR v_dom IN SELECT a.domain FROM core.advisors a
                  WHERE a.plan_step AND core.fn_package_active(a.package)
                    AND EXISTS (SELECT 1 FROM agent.advisor_plans x WHERE x.domain = a.domain AND x.status = 'active')
                  ORDER BY a.domain LOOP
        v_res := core.fn_plan_rollout_next(v_dom, v_pid);
        IF (v_res->>'loser')::boolean IS TRUE THEN RETURN v_empty; END IF;
        IF jsonb_array_length(v_res->'messages') > 0 THEN
            IF p->>'budget' = 'true' AND NOT core.fn_proactive_claim(v_pid, 'plan_rollout', 'normal') THEN
                PERFORM core.fn_notify_resolve(l->>'source', l->>'key')
                   FROM jsonb_array_elements(v_res->'messages') m
                  CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(m->'latches') = 'array' AND m->'latches' <> '[]'::jsonb THEN m->'latches'
                                                               WHEN m ? 'latch' THEN jsonb_build_array(m->'latch') ELSE '[]'::jsonb END) l;
                RETURN v_empty;
            END IF;
            RETURN jsonb_build_object('step', v_res->'step', 'domain', v_dom,
                'messages', (SELECT jsonb_agg(m || jsonb_build_object('chat_id', v_chat)) FROM jsonb_array_elements(v_res->'messages') m));
        END IF;
    END LOOP;
    RETURN v_empty;
EXCEPTION WHEN OTHERS THEN
    RETURN v_empty;
END;
$$;
