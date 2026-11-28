-- ============================================================
-- core.fn_advisor_hint_prompt(p_chat_id) — ein brennender Kontohinweis als offene Frage der Art hint (WRITE)
--   Gerufen von core.fn_next_chat_prompt, wenn im Chat nichts offen ist und nichts wartet. Nur waehrend eines laufenden
--   Plan-Gespraechs (Haushalts-Entwurf einer Domaene mit core.advisors.hints_fn, Paket aktiv, in den letzten 2 Stunden
--   bearbeitet wie der Interview-Pin; ein pausierter Entwurf bringt in fremden Gespraechen keine Karte) und nur fuer den, der den Plan
--   schreiben darf (agent.fn_check_write_permission der plan_context-Regel). Je Domaene: Hinweise aus der hints_fn
--   ({key, class, text_key, params {amount?, currency?, date?}, pending_entry?, kind, account}; kind/account nur in
--   der payload-summary), Merker "spaeter" (core.notification_state advisor_hint '<domain>:<key>') fuer Hinweise,
--   die es nicht mehr gibt, werden zurueckgesetzt (core.fn_notify_resolve: der Hinweis hat sich in den Daten erledigt).
--   Gewaehlt wird der erste Hinweis der Klasse urgent ohne Merker, zu dem es an diesem Entwurf noch keine Zeile gibt (ein
--   Hinweis kommt in einem Gespraech nur einmal). Karte: Warnzeile text_key mit params (amount -> core.fn_fmt_money,
--   date -> core.fn_ui_date in der Sprache des Chats), Knoepfe now/later; nennt eine offene Vormerkung das Konto (pending_entry)
--   enter/later (das Eintragen behebt die Luecke).
--   Rueckgabe die id der neuen Zeile (status queued; der Aufrufer oeffnet sie) oder NULL.
--   Familie: core.fn_prompt_answer_hint(p) = answer_fn der Art hint: now -> continue mit festem Auftrag an den Berater;
--     enter -> continue mit dem Auftrag, die vereinbarten Eintraege jetzt anzubieten;
--     later -> Merker (core.fn_advisor_defer_hint_key, 30 Tage), then none.
--   Familie: agent.fn_advisor_defer_hint(p) — Werkzeug tool_defer_hint (ohne Gate; "bitte nicht mehr danach fragen"):
--     {domain, chat_id, key} -> {ok:true, key} | {ok:false, code: invalid_input | unknown_hint {keys} | no_permission}.
--   VOLATILE, INVOKER (Host-Cred), search_path gepinnt; Paket-fns nur ueber Registry + to_regprocedure.
--   Tests: tests/db/finance/test_fn_advisor_hints.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_hint_prompt(p_chat_id text)
RETURNS bigint
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    r       record;
    v_pid   text;
    v_lang  text;
    v_perm  text;
    v_plan  int;
    v_fn    regprocedure;
    v_hints jsonb;
    v_h     jsonb;
    v_key   text;
    v_par   jsonb;
    v_id    bigint;
BEGIN
    IF NOT core.fn_chat_id_ok(p_chat_id) THEN
        RETURN NULL;
    END IF;
    v_pid := core.fn_chat_person(p_chat_id)->>'person_id';
    IF v_pid IS NULL THEN
        RETURN NULL;
    END IF;
    v_lang := agent.fn_person_lang(v_pid)->>'lang';
    FOR r IN
        SELECT a.domain, a.plan_context, a.hints_fn, a.advisor_agent
          FROM core.advisors a
          JOIN core.package_registry pr ON pr.package = a.package AND pr.status = 'active'
         WHERE a.hints_fn IS NOT NULL AND a.advisor_agent IS NOT NULL
         ORDER BY a.domain
    LOOP
        CONTINUE WHEN COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = r.plan_context), 'household') <> 'household';
        SELECT ap.id INTO v_plan FROM agent.advisor_plans ap WHERE ap.domain = r.domain AND ap.person_id IS NULL AND ap.status = 'draft'
           AND ap.updated_at > now() - interval '2 hours';
        CONTINUE WHEN v_plan IS NULL;
        v_perm := COALESCE((SELECT cs.write_permission FROM core.context_scopes cs WHERE cs.context_name = r.plan_context), 'owner_only');
        CONTINUE WHEN agent.fn_check_write_permission(v_perm, p_chat_id, NULL) IS NOT NULL;
        v_fn := to_regprocedure(r.hints_fn || '(text)');
        CONTINUE WHEN v_fn IS NULL;
        BEGIN
            EXECUTE format('SELECT %s($1)', v_fn::regproc) INTO v_hints USING r.domain;
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;
        END;
        CONTINUE WHEN jsonb_typeof(v_hints) IS DISTINCT FROM 'array';

        PERFORM core.fn_notify_resolve('advisor_hint', n.key)
           FROM core.notification_state n
          WHERE n.source = 'advisor_hint' AND left(n.key, length(r.domain) + 1) = r.domain || ':'
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_hints) h WHERE r.domain || ':' || (h->>'key') = n.key);

        SELECT h INTO v_h FROM jsonb_array_elements(v_hints) WITH ORDINALITY AS x(h, i)
         WHERE h->>'class' = 'urgent'
           AND NOT EXISTS (SELECT 1 FROM core.notification_state n
                            WHERE n.source = 'advisor_hint' AND n.key = r.domain || ':' || (h->>'key') AND n.state = 'fired'
                              AND (n.expires_at IS NULL OR n.expires_at > now()))
           AND NOT EXISTS (SELECT 1 FROM agent.chat_prompts c
                            WHERE c.plan_id = v_plan AND c.kind = 'hint' AND c.payload->>'key' = h->>'key')
         ORDER BY i LIMIT 1;
        CONTINUE WHEN v_h IS NULL;

        v_key := v_h->>'key';
        v_par := COALESCE(v_h->'params', '{}'::jsonb);
        IF v_par ? 'amount' THEN
            v_par := v_par || jsonb_build_object('amount', core.fn_fmt_money((v_par->>'amount')::numeric, COALESCE(v_par->>'currency', 'EUR'), v_lang));
        END IF;
        IF v_par ? 'date' THEN
            v_par := v_par || jsonb_build_object('date', core.fn_ui_date((v_par->>'date')::date));
        END IF;
        INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, plan_id, ord, status, card, options, payload)
        VALUES (p_chat_id, v_pid, r.advisor_agent, 'hint', v_plan, 1, 'queued',
                jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('kind', 'warning', 'key', v_h->>'text_key', 'params', v_par))),
                CASE WHEN COALESCE((v_h->>'pending_entry')::boolean, false)
                     THEN '[{"key":"enter","label_key":"core.prompt.button.enter_now"},{"key":"later","label_key":"core.prompt.button.later"}]'::jsonb
                     ELSE '[{"key":"now","label_key":"core.prompt.button.clear_now"},{"key":"later","label_key":"core.prompt.button.later"}]'::jsonb END,
                jsonb_build_object('domain', r.domain, 'key', v_key, 'label', 'hint ' || v_key,
                    'summary', format('%s on %s (problem date %s, amount %s %s)', v_h->>'kind', v_h->>'account',
                                      v_h->'params'->>'date', v_h->'params'->>'amount', v_h->'params'->>'currency')))
        RETURNING id INTO v_id;
        RETURN v_id;
    END LOOP;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_hint_prompt(text) FROM public;

CREATE OR REPLACE FUNCTION core.fn_prompt_answer_hint(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pay jsonb := p->'prompt'->'payload';
BEGIN
    IF p->>'key' = 'later' THEN
        PERFORM core.fn_advisor_defer_hint_key(v_pay->>'domain', v_pay->>'key');
        RETURN jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.hint_later', p->>'lang'), 'then', 'none');
    ELSIF p->>'key' = 'enter' THEN
        RETURN jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.hint_enter', p->>'lang'), 'then', 'continue',
            'continue', jsonb_build_object('agent', p->'prompt'->>'agent', 'as', 'task',
                'text', format('The user wants to enter the agreed items now that concern this account hint (%s): %s. Offer the list '
                               || 'of agreed items to enter now (handoff overview); then continue the plan where it stopped.', v_pay->>'key', v_pay->>'summary')));
    ELSIF p->>'key' = 'now' THEN
        RETURN jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.hint_now', p->>'lang'), 'then', 'continue',
            'continue', jsonb_build_object('agent', p->'prompt'->>'agent', 'as', 'task',
                'text', format('The user wants to clear this account hint now (%s): %s. Explain it in at most four short sentences '
                               || 'and propose what to do; then continue the plan where it stopped.', v_pay->>'key', v_pay->>'summary')));
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_option');
END;
$$;
REVOKE ALL ON FUNCTION core.fn_prompt_answer_hint(jsonb) FROM public;

CREATE OR REPLACE FUNCTION agent.fn_advisor_defer_hint(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain text := NULLIF(btrim(COALESCE(p->>'domain', '')), '');
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_key    text := btrim(COALESCE(p->>'key', ''));
    v_ctx    text;
    v_fnname text;
    v_fn     regprocedure;
    v_hints  jsonb := '[]'::jsonb;
    v_err    text;
BEGIN
    IF v_domain IS NULL OR NOT core.fn_chat_id_ok(v_chat) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_input', 'reason', 'domain and chat_id are required');
    END IF;
    SELECT a.plan_context, a.hints_fn INTO v_ctx, v_fnname FROM core.advisors a WHERE a.domain = v_domain;
    v_err := agent.fn_check_write_permission(
                 COALESCE((SELECT cs.write_permission FROM core.context_scopes cs WHERE cs.context_name = COALESCE(v_ctx, v_domain || '_planning')), 'owner_only'),
                 v_chat, NULL);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_permission', 'reason', v_err);
    END IF;
    v_fn := to_regprocedure(v_fnname || '(text)');
    IF v_fn IS NOT NULL THEN
        EXECUTE format('SELECT %s($1)', v_fn::regproc) INTO v_hints USING v_domain;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_hints, '[]'::jsonb)) h WHERE h->>'key' = v_key) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_hint',
            'keys', COALESCE((SELECT jsonb_agg(h->'key') FROM jsonb_array_elements(COALESCE(v_hints, '[]'::jsonb)) h), '[]'::jsonb),
            'reason', 'unknown hint key: use the key of a warning from the snapshot');
    END IF;
    PERFORM core.fn_advisor_defer_hint_key(v_domain, v_key);
    RETURN jsonb_build_object('ok', true, 'key', v_key);
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_advisor_defer_hint(jsonb) FROM public;
