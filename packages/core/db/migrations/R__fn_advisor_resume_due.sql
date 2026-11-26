-- ============================================================
-- core.fn_advisor_resume_due(p) — Erinnerung an eine angefangene Beratung (WRITE)
--   Wer einen Plan-Entwurf liegen laesst, bekommt hoechstens zwei Nachrichten (Stufe 1 nach advisor.resume_first_days,
--   Stufe 2 nach advisor.resume_last_days, Defaults 4/14; first >= last -> Defaults), dann Ruhe. Nach dem
--   Veroeffentlichen erinnert sie einmal an noch offene Uebergabe-Punkte. Die DB entscheidet und baut die Text-
--   Struktur; der Cron agent.advisor.cron_resume_nudge rendert und sendet nur.
--   p: { order:["core:household","<pkg>:<key>",…], plan_order:["<domain>",…] } — build-time wie beim Orchestrator, damit
--      core.fn_get_next_step dieselbe Antwort gibt wie beim Gruss.
--   Ausserhalb core.fn_in_reminder_window() -> leere Liste. Je Person mit Telegram-Verbindung, hoechstens ein Item:
--     * core.fn_reminder_allowed('advisor_resume', person) (Knopf rem:off:advisor_resume, Notschalter
--       cron_enable.advisor_resume) vor jedem Merker.
--     * R8: lebender Denk-Schalter des Chats (agent.thinking_lease) oder offene Freigabe-Karte
--       (agent.fn_get_hitl_pending_state) -> heute nicht (naechster Lauf).
--     * R7: heute schon ein Gruss-Vorschlag (ein next_step_day-Merker aus core.fn_next_step_offer_keys belegt) -> nicht.
--       Nur lesend: der Versand schreibt nichts in die Merker des naechsten Schritts.
--     * R6: core.fn_get_next_step mit p.order/p.plan_order.
--       - kind plan, state draft -> Entwurfs-Erinnerung fuer genau diese Domain (can_write und reif sind dort geprueft;
--         "Angefangenes geht vor" macht das auch bei offenen Einrichtungs-Abschnitten wahr). Stufen ueber
--         core.fn_nudge_stage: source 'advisor_resume', Merker '<pid>:<domain>:<plan_id>:1|2' (ein neuer Entwurf hat
--         neue Merker; core.fn_get_next_step liest den Stufe-2-Merker fuer das Ende des Vorrangs), Slot
--         'advisor_resume', nur Entwuerfe juenger als advisor.rollout_draft_stale_days (30), Stillstand und Re-Arm ab draft.updated_at, Abstand 7 Tage, Re-Arm-Mindestabstand
--         advisor.resume_rearm_days (14), Quellen-Grenze onboarding_nudge.
--       - kind nicht section -> Uebergabe-Erinnerung (einmal): erste Domain in p.plan_order mit can_write, aktivem Plan
--         ohne Entwurf (core.fn_advisor_plan_status state gaps|complete|enter) und offenen Punkten (core.fn_handoff_overview,
--         via 'resume'), deren Rollout-Liste fuer dieselbe hoechste Aufgabe festgeschrieben ist (plan_rollout
--         '<domain>:<household|pid>:handoff:<max>', core.fn_plan_rollout_latch done, nur lesend) und vor
--         >= advisor.resume_handoff_days (14) kam. Merker '<pid>:<domain>:handoff:<max>:1' ueber core.fn_nudge_stage
--         (eine Stufe), eine neue hoechste Aufgabe ist erst nach ihrer Rollout-Liste wieder moeglich.
--   Thema ({topic}): das zuletzt Gespeicherte im Entwurf (Maximum ueber Abschnitts- und Thema-saved_at, bei Gleichstand
--     das Thema): Thema-Text in Originalsprache, sonst der Katalog-Name <pkg>.plan_section.<key>, sonst ohne Teilsatz.
--   Rueckgabe {ok:true, items:[{person_id, chat_id, kind:'draft'|'handoff', stage, domain, package, plan_id, revision,
--     topic, open_tasks, max_task_id, msg:[tpl…], buttons:[{text_key, data}]}]}.
--     draft: msg[0] core.advisor_resume.stage1|stage2 (revision: _revision) mit {plan} = <pkg>.plan.name und
--       {topic_part} = core.advisor_resume.topic_part {topic} oder ''; msg[1] bei offenen Punkten
--       core.advisor_resume.open_tasks {n} bzw. open_task_one; Knopf [Weiter] plan:resume:<domain>:<plan_id>.
--     handoff: msg[0] core.handoff.overview (why_resume); Knopf [Durchgehen] handoff:<domain>:<max>.
--     Den zweiten Knopf [Nicht mehr erinnern] (rem:off:advisor_resume) setzt der Cron fest (cron_toggle_lint sucht ihn dort).
--   VOLATILE (schreibt Merker und Budget) -> im Cron einmal in einer MATERIALIZED CTE aufrufen. INVOKER unter der
--   Host-Cred des Crons, search_path gepinnt, Body schema-qualifiziert. Kein Write-Tool: nur Merker (wie das Analog).
--   Tests: tests/db/core/test_fn_advisor_resume_due.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_resume_due(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_out    jsonb := '[]'::jsonb;
    v_porder jsonb := CASE WHEN jsonb_typeof(p->'plan_order') = 'array' THEN p->'plan_order' ELSE '[]'::jsonb END;
    v_first  int;
    v_last   int;
    v_rearm  int;
    v_hdays  int;
    v_stale  int;
    r        record;
    v_chat   bigint;
    v_keys   jsonb;
    v_step   jsonb;
    v_pkg    text;
    v_scope  text;
    v_target text;
    v_draft  agent.advisor_plans%ROWTYPE;
    v_rev    boolean;
    v_stage  int;
    v_sec    text;
    v_tname  text;
    v_topic  jsonb;
    v_open   int;
    v_msg    jsonb;
    v_pl     jsonb;
    v_ho     jsonb;
    v_max    int;
    v_rkey   text;
    v_rat    timestamptz;
BEGIN
    IF NOT core.fn_in_reminder_window() THEN
        RETURN jsonb_build_object('ok', true, 'items', v_out);
    END IF;
    v_first := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'resume_first_days'), '')::int, 4);
    v_last  := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'resume_last_days'), '')::int, 14);
    IF v_first >= v_last THEN v_first := 4; v_last := 14; END IF;
    v_rearm := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'resume_rearm_days'), '')::int, 14);
    v_hdays := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'resume_handoff_days'), '')::int, 14);
    v_stale := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'rollout_draft_stale_days'), '')::int, 30);

    FOR r IN SELECT ap.person_id FROM agent.persons ap ORDER BY ap.person_id LOOP
        v_chat := agent.fn_person_chat_id(r.person_id);
        CONTINUE WHEN v_chat IS NULL;
        CONTINUE WHEN NOT core.fn_reminder_allowed('advisor_resume', r.person_id);
        CONTINUE WHEN EXISTS (SELECT 1 FROM agent.thinking_lease tl WHERE tl.chat_id = v_chat AND tl.expires_at > now())
                   OR agent.fn_get_hitl_pending_state(v_chat) IS NOT NULL;
        v_keys := core.fn_next_step_offer_keys(r.person_id, '', '', 0);
        CONTINUE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(v_keys->'day', '[]'::jsonb)) k
                               WHERE core.fn_notify_told('next_step_day', k));

        v_step := core.fn_get_next_step(jsonb_build_object('chat_id', v_chat::text, 'order', p->'order', 'plan_order', v_porder));

        IF v_step->>'kind' = 'plan' AND v_step->>'state' = 'draft' THEN
            SELECT a.package, COALESCE(cs.scope, 'household') INTO v_pkg, v_scope
              FROM core.advisors a LEFT JOIN core.context_scopes cs ON cs.context_name = a.plan_context
             WHERE a.domain = v_step->>'domain';
            v_target := CASE WHEN v_scope = 'per_user' THEN r.person_id END;
            v_draft := NULL;
            SELECT * INTO v_draft FROM agent.advisor_plans ap
             WHERE ap.domain = v_step->>'domain' AND ap.person_id IS NOT DISTINCT FROM v_target AND ap.status = 'draft';
            CONTINUE WHEN v_draft.id IS NULL OR v_draft.updated_at <= now() - make_interval(days => v_stale);

            v_stage := core.fn_nudge_stage(jsonb_build_object(
                'source', 'advisor_resume', 'key_prefix', r.person_id || ':' || v_draft.domain || ':' || v_draft.id,
                'person_id', r.person_id, 'slot', 'advisor_resume', 'idle_since', v_draft.updated_at,
                'rearm_since', v_draft.updated_at, 'first_days', v_first, 'last_days', v_last, 'gap_days', 7,
                'rearm_days', v_rearm, 'exclusive_sources', jsonb_build_array('onboarding_nudge')));
            CONTINUE WHEN v_stage IS NULL;

            v_rev := EXISTS (SELECT 1 FROM agent.advisor_plans ap WHERE ap.domain = v_draft.domain
                              AND ap.person_id IS NOT DISTINCT FROM v_target AND ap.status = 'active');
            -- zuletzt Gespeichertes: Abschnitte (pri 1) und ihre Themen (pri 0); kaputte Stempel zaehlen nicht
            v_sec := NULL; v_tname := NULL;
            SELECT x.sec, x.topic INTO v_sec, v_tname FROM (
                SELECT s.key AS sec, NULL::text AS topic, s.value->>'saved_at' AS at, 1 AS pri
                  FROM jsonb_each(CASE WHEN jsonb_typeof(v_draft.interview_state) = 'object' THEN v_draft.interview_state ELSE '{}'::jsonb END) s
                 WHERE jsonb_typeof(s.value) = 'object'
                UNION ALL
                SELECT s.key, t->>'topic', t->>'saved_at', 0
                  FROM jsonb_each(CASE WHEN jsonb_typeof(v_draft.interview_state) = 'object' THEN v_draft.interview_state ELSE '{}'::jsonb END) s
                 CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(s.value->'topics') = 'array' THEN s.value->'topics' ELSE '[]'::jsonb END) t
                 WHERE jsonb_typeof(t) = 'object'
            ) x
             WHERE x.at IS NOT NULL AND pg_input_is_valid(x.at, 'timestamptz')
             ORDER BY x.at::timestamptz DESC, x.pri
             LIMIT 1;
            v_topic := CASE WHEN NULLIF(btrim(v_tname), '') IS NOT NULL THEN to_jsonb(left(btrim(v_tname), 60))
                            WHEN v_sec IS NOT NULL AND EXISTS (SELECT 1 FROM core.ui_texts ut WHERE ut.key = v_pkg || '.plan_section.' || v_sec)
                            THEN core.fn_ui_tpl(v_pkg || '.plan_section.' || v_sec) END;

            SELECT count(*) INTO v_open FROM agent.handoff_tasks t
             WHERE t.domain = v_draft.domain AND t.person_id = r.person_id AND t.status IN ('open', 'working');

            v_msg := jsonb_build_array(core.fn_ui_tpl(
                CASE WHEN v_stage = 1 AND NOT v_rev THEN 'core.advisor_resume.stage1'
                     WHEN v_stage = 1 THEN 'core.advisor_resume.stage1_revision'
                     WHEN NOT v_rev THEN 'core.advisor_resume.stage2'
                     ELSE 'core.advisor_resume.stage2_revision' END,
                jsonb_build_object('plan', core.fn_ui_tpl(v_pkg || '.plan.name'),
                    'topic_part', CASE WHEN v_topic IS NULL THEN to_jsonb(''::text)
                                       ELSE core.fn_ui_tpl('core.advisor_resume.topic_part', jsonb_build_object('topic', v_topic)) END)));
            IF v_open = 1 THEN
                v_msg := v_msg || jsonb_build_array(core.fn_ui_tpl('core.advisor_resume.open_task_one'));
            ELSIF v_open > 1 THEN
                v_msg := v_msg || jsonb_build_array(core.fn_ui_tpl('core.advisor_resume.open_tasks', jsonb_build_object('n', v_open)));
            END IF;

            v_out := v_out || jsonb_build_array(jsonb_build_object(
                'person_id', r.person_id, 'chat_id', v_chat, 'kind', 'draft', 'stage', v_stage, 'domain', v_draft.domain,
                'package', v_pkg, 'plan_id', v_draft.id, 'revision', v_rev, 'topic', v_topic, 'open_tasks', v_open,
                'max_task_id', NULL, 'msg', v_msg,
                'buttons', jsonb_build_array(
                    jsonb_build_object('text_key', 'core.nudge.btn_continue', 'data', 'plan:resume:' || v_draft.domain || ':' || v_draft.id))));

        ELSIF COALESCE(v_step->>'kind', '') <> 'section' THEN
            FOR v_pl IN
                SELECT pl FROM jsonb_array_elements(core.fn_advisor_plan_status(v_chat::text)) pl
                  LEFT JOIN jsonb_array_elements_text(v_porder) WITH ORDINALITY AS o(d, oi) ON o.d = pl->>'domain'
                 WHERE (pl->>'can_write')::boolean AND pl->>'state' IN ('gaps', 'complete', 'enter')
                 ORDER BY COALESCE(o.oi, 100000), pl->>'domain'
            LOOP
                v_ho := core.fn_handoff_overview(jsonb_build_object('domain', v_pl->>'domain', 'chat_id', v_chat::text, 'via', 'resume'));
                v_max := NULLIF(v_ho->>'max_task_id', '')::int;
                CONTINUE WHEN v_max IS NULL;
                v_rkey := (v_pl->>'domain') || ':' || CASE WHEN (v_pl->>'per_user')::boolean THEN r.person_id ELSE 'household' END
                          || ':handoff:' || v_max;
                CONTINUE WHEN core.fn_plan_rollout_latch(v_rkey) IS DISTINCT FROM 'done';
                SELECT ns.last_fired_at INTO v_rat FROM core.notification_state ns WHERE ns.source = 'plan_rollout' AND ns.key = v_rkey;
                v_stage := core.fn_nudge_stage(jsonb_build_object(
                    'source', 'advisor_resume', 'key_prefix', r.person_id || ':' || (v_pl->>'domain') || ':handoff:' || v_max,
                    'person_id', r.person_id, 'slot', 'advisor_resume', 'idle_since', v_rat, 'rearm_since', NULL,
                    'first_days', v_hdays, 'last_days', 36500, 'gap_days', 0, 'rearm_days', 0,
                    'exclusive_sources', jsonb_build_array('onboarding_nudge')));
                CONTINUE WHEN v_stage IS NULL;
                v_out := v_out || jsonb_build_array(jsonb_build_object(
                    'person_id', r.person_id, 'chat_id', v_chat, 'kind', 'handoff', 'stage', 1, 'domain', v_pl->>'domain',
                    'package', v_pl->>'package', 'plan_id', NULL, 'revision', false, 'topic', NULL,
                    'open_tasks', (v_ho->>'count')::int, 'max_task_id', v_max, 'msg', jsonb_build_array(v_ho->'msg'),
                    'buttons', jsonb_build_array(
                        jsonb_build_object('text_key', 'core.handoff.btn_go', 'data', 'handoff:' || (v_pl->>'domain') || ':' || v_max))));
                EXIT;
            END LOOP;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'items', v_out);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_resume_due(jsonb) FROM public;
