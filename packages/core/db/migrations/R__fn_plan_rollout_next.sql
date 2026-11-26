-- ============================================================
-- fn_plan_rollout_next (ATOMIC WRITE) — der eine naechste Schritt nach dem Veroeffentlichen
--   Eingabe: p_domain text, p_person text (person_id).
--   Leitet aus dem Bestand ab, was als Naechstes dran ist (level-triggered, kein Status). Reihenfolge: 0 [Plan durchsehen],
--   1 Uebergabe-Liste (Merker core.fn_handoff_latch_key: einmal je hoechster Aufgabe und veroeffentlichter Version),
--   waehrend des Durchgehens (Claim juenger als advisor.handoff_claim_ttl_minutes) still warten, 3 Paket-Schritt
--   (core.advisors.rollout_fn, z. B. Bank-Zettel) schon vor dem Warten auf liegen gebliebene Eintraege, 2 still warten,
--   solange ein Eintrag open/working ist (ohne Frist; deferred und cancelled halten nicht auf), fix Korrektur-Schritt,
--   4 Wert-Waechter, 5 Schluss. advisor.rollout_wait_days gilt nur fuer Schritt 0 und das wait eines Paket-Schritts.
--   fix: Zeilen des Ersatzweg-Registers (core.fn_handoff_register) mit possible_now (nach einem Update geht, was vorher
--   nicht ging); eine Nachricht core.rollout.fix_offer {n} bzw. fix_offer_one, Knopf core.handoff.btn_go mit
--   handoff:<domain>:<max_task_id>:fix (core.fn_handle_handoff_cb), je Aufgabe ein Merker '<prefix>fix:<task_id>' in latches
--   (ein Angebot je Aufgabe; nie bei offenem Entwurf).
--   Offener Entwurf (je Domain und Person) juenger als advisor.rollout_draft_stale_days: 0, 4, 5 entfallen, 1 wartet (step 1, wait).
--   Haushaltsplan: nur der Owner bekommt Schritte; per_user: jede Person ihre eigenen, ohne watch:on und plan:share.
--   Beansprucht ueber core.fn_should_notify('plan_rollout', key, '30 minutes'); festschreiben macht der Sender (core.fn_notify_commit).
--   Rueckgabe {step (0..5 oder 'fix'), wait?, loser?, messages:[{msg:[tpl] | lines:[[tpl…]|null], buttons:[{text_key,params?,data}], memory_agent?,
--   latch:{source,key}, latches?}]} (lines = mehrzeilige Nachricht eines Paket-Schritts, core.sub_plan_rollout_next);
--   unbekannte Domain, fremde Person oder kein aktiver Plan -> {step:null, messages:[]}.
--   Nachrichten ohne Knopf werden verworfen. INVOKER unter der Host-Cred. Tests: tests/db/core/test_fn_plan_rollout_next.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_rollout_next(p_domain text, p_person text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_adv     core.advisors%ROWTYPE;
    v_pkg     text;
    v_scope   text;
    v_pid     text;
    v_who     text;
    v_owner   text := agent.fn_owner_person_id();
    v_plan    agent.advisor_plans%ROWTYPE;
    v_sync    boolean;
    v_draft   boolean;
    v_wait    int;
    v_gap     int;
    v_stale   int;
    v_prefix  text;
    v_key     text;
    v_state   text;
    v_at      timestamptz;
    v_cnt     int;
    v_max     int;
    v_items   jsonb;
    v_res     jsonb;
    v_buttons jsonb;
    v_latches jsonb;
    v_chat    text;
    v_share   jsonb;
    v_off     boolean;
    v_shown   int;
    v_slot    int;
    v_live    boolean;
    v_fix     jsonb;
    v_ttl     int := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
BEGIN
    SELECT * INTO v_adv FROM core.advisors a WHERE a.domain = p_domain;
    IF NOT FOUND THEN RETURN jsonb_build_object('step', NULL, 'messages', '[]'::jsonb); END IF;
    v_pkg := v_adv.package;
    v_scope := COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = v_adv.plan_context), 'household');
    IF v_scope = 'per_user' THEN
        v_pid := p_person;
    ELSIF p_person IS DISTINCT FROM v_owner THEN
        RETURN jsonb_build_object('step', NULL, 'messages', '[]'::jsonb);
    END IF;
    SELECT * INTO v_plan FROM agent.advisor_plans p
     WHERE p.domain = p_domain AND p.person_id IS NOT DISTINCT FROM v_pid AND p.status = 'active';
    IF NOT FOUND THEN RETURN jsonb_build_object('step', NULL, 'messages', '[]'::jsonb); END IF;

    v_who := COALESCE(v_pid, 'household');
    v_prefix := p_domain || ':' || v_who || ':' || v_plan.version || ':';
    v_sync := COALESCE(core.fn_config_get(v_pkg, 'advisor', 'plan_sync_required'), 'false') = 'true';
    v_wait := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'rollout_wait_days'), '')::int, 7);
    v_gap := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'rollout_gap_hours'), '')::int, 20);
    v_stale := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'rollout_draft_stale_days'), '')::int, 30);
    v_draft := EXISTS (SELECT 1 FROM agent.advisor_plans d WHERE d.domain = p_domain AND d.person_id IS NOT DISTINCT FROM v_pid
                        AND d.status = 'draft' AND d.updated_at > now() - make_interval(days => v_stale));

    -- Schritt 0: [Plan durchsehen]
    IF v_plan.synced_at IS NULL AND v_sync AND NOT v_draft THEN
        v_key := v_prefix || '0';
        v_state := core.fn_plan_rollout_latch(v_key);
        IF v_state = 'pending' THEN RETURN jsonb_build_object('step', 0, 'loser', true, 'messages', '[]'::jsonb); END IF;
        IF v_state = 'free' THEN
            IF NOT core.fn_should_notify('plan_rollout', v_key, interval '30 minutes') THEN
                RETURN jsonb_build_object('step', 0, 'loser', true, 'messages', '[]'::jsonb);
            END IF;
            RETURN jsonb_build_object('step', 0, 'messages', jsonb_build_array(jsonb_build_object(
                'msg', jsonb_build_array(jsonb_build_object('kind', 'tpl', 'value', 'core.rollout.scan_offer')),
                'buttons', jsonb_build_array(jsonb_build_object('text_key', 'core.rollout.btn_scan', 'data', 'plan:scan:' || p_domain || ':' || v_plan.version)),
                'memory_agent', v_adv.advisor_agent,
                'latch', jsonb_build_object('source', 'plan_rollout', 'key', v_key))));
        END IF;
        SELECT n.last_fired_at INTO v_at FROM core.notification_state n WHERE n.source = 'plan_rollout' AND n.key = v_key;
        IF v_at > now() - make_interval(days => v_wait) THEN
            RETURN jsonb_build_object('step', 0, 'wait', true, 'messages', '[]'::jsonb);
        END IF;
    END IF;

    -- Schritt 1: Uebergabe-Liste, einmal je hoechster Aufgabe und veroeffentlichter Version. Warten zaehlt auch laufende
    -- Claims (sonst liefe die Abfolge waehrend des Durchgehens weiter); Liste, Knopf und Schluessel (latch_key) kommen aus
    -- core.fn_handoff_overview wie beim Berater-Tool, damit dessen Merker denselben Schluessel trifft.
    SELECT count(*),
           COALESCE(bool_or(t.status = 'working' AND t.claimed_at > now() - make_interval(mins => v_ttl)), false)
      INTO v_cnt, v_live
      FROM agent.handoff_tasks t
     WHERE t.domain = p_domain AND t.person_id = p_person AND t.status IN ('open', 'working');
    IF v_cnt > 0 THEN
        -- Offener Entwurf: das Gespraech laeuft noch, die Liste kommt an dessen Ende (Publish oder tool_send_handoff_overview).
        IF v_draft THEN RETURN jsonb_build_object('step', 1, 'wait', true, 'messages', '[]'::jsonb); END IF;
        v_res := core.fn_handoff_overview(jsonb_build_object('domain', p_domain, 'chat_id', core.fn_person_chat_id(p_person)::text, 'via', 'rollout'));
        v_max := NULLIF(v_res->>'max_task_id', '')::int;
        v_key := v_res->>'latch_key';
        v_state := CASE WHEN v_max IS NULL OR v_key IS NULL OR core.fn_handoff_list_shown_at(v_key) IS NOT NULL THEN 'done'
                        ELSE core.fn_plan_rollout_latch(v_key) END;
        IF v_state = 'pending' THEN RETURN jsonb_build_object('step', 1, 'loser', true, 'messages', '[]'::jsonb); END IF;
        IF v_state = 'free' THEN
            IF NOT core.fn_should_notify('plan_rollout', v_key, interval '30 minutes') THEN
                RETURN jsonb_build_object('step', 1, 'loser', true, 'messages', '[]'::jsonb);
            END IF;
            RETURN jsonb_build_object('step', 1, 'messages', jsonb_build_array(jsonb_build_object(
                'msg', jsonb_build_array(v_res->'msg'),
                'buttons', jsonb_build_array(jsonb_build_object('text_key', 'core.handoff.btn_go', 'data', 'handoff:' || p_domain || ':' || v_max)),
                'latch', jsonb_build_object('source', 'plan_rollout', 'key', v_key))));
        END IF;
        -- Durchgehen laeuft (lebender Claim): still warten, auch kein Bank-Zettel zwischen zwei Eintraegen
        IF v_live THEN RETURN jsonb_build_object('step', 2, 'wait', true, 'messages', '[]'::jsonb); END IF;
    END IF;

    -- Schritt 3: Paket-Schritt (Fehler des Pakets sind neutral, die Schritte danach laufen). Laeuft vor dem Warten auf
    -- noch offene Eintraege: der Bank-Zettel einer Eintrage-Runde kommt an ihrem Ende, liegen gebliebene halten ihn nicht auf.
    v_res := NULL;
    IF v_adv.rollout_fn IS NOT NULL AND to_regprocedure(v_adv.rollout_fn || '(text,text)') IS NOT NULL THEN
        BEGIN
            -- rollout_fn ist per CHECK auf <schema>.fn_<name> begrenzt, Name nie aus Nutzereingabe.
            EXECUTE format('SELECT %s($1, $2)', v_adv.rollout_fn) INTO v_res USING p_domain, p_person;
        EXCEPTION WHEN OTHERS THEN
            v_res := NULL;
        END;
        IF jsonb_typeof(v_res->'messages') = 'array' THEN
            v_items := COALESCE((SELECT jsonb_agg(m) FROM jsonb_array_elements(v_res->'messages') m
                                  WHERE jsonb_array_length(COALESCE(NULLIF(m->'buttons', 'null'::jsonb), '[]'::jsonb)) > 0), '[]'::jsonb);
            IF jsonb_array_length(v_items) > 0 THEN
                RETURN jsonb_build_object('step', 3, 'messages', v_items);
            END IF;
        END IF;
    END IF;

    -- Schritt 2: still warten, solange etwas open/working ist, ohne Frist (nie "eingerichtet", bevor es stimmt);
    -- deferred und cancelled halten nicht auf
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('step', 2, 'wait', true, 'messages', '[]'::jsonb);
    END IF;

    IF v_res IS NOT NULL THEN
        IF (v_res->>'wait')::boolean IS TRUE THEN
            v_key := v_prefix || '3wait';
            PERFORM core.fn_should_notify('plan_rollout', v_key, NULL);
            SELECT n.last_fired_at INTO v_at FROM core.notification_state n WHERE n.source = 'plan_rollout' AND n.key = v_key;
            IF v_at > now() - make_interval(days => v_wait) THEN
                RETURN jsonb_build_object('step', 3, 'wait', true, 'messages', '[]'::jsonb);
            END IF;
        END IF;
    END IF;

    IF v_draft THEN RETURN jsonb_build_object('step', NULL, 'messages', '[]'::jsonb); END IF;

    -- Korrektur-Schritt: je nachholbarer Aufgabe ein eigener Merker; laufende Beanspruchung (pending) eines anderen Laufs
    -- wird uebersprungen, nur frisch beanspruchte Aufgaben kommen in die Nachricht.
    v_fix := '[]'::jsonb;
    v_max := NULL;
    FOR v_cnt IN
        SELECT (e->>'task_id')::int FROM jsonb_array_elements(core.fn_handoff_register(p_domain, core.fn_person_chat_id(p_person)::text)) e
         WHERE (e->>'possible_now')::boolean ORDER BY (e->>'task_id')::int
    LOOP
        v_key := v_prefix || 'fix:' || v_cnt;
        CONTINUE WHEN core.fn_plan_rollout_latch(v_key) <> 'free';
        CONTINUE WHEN NOT core.fn_should_notify('plan_rollout', v_key, interval '30 minutes');
        v_fix := v_fix || jsonb_build_object('source', 'plan_rollout', 'key', v_key);
        v_max := v_cnt;
    END LOOP;
    IF jsonb_array_length(v_fix) > 0 THEN
        RETURN jsonb_build_object('step', 'fix', 'messages', jsonb_build_array(jsonb_build_object(
            'msg', jsonb_build_array(CASE WHEN jsonb_array_length(v_fix) = 1 THEN core.fn_ui_tpl('core.rollout.fix_offer_one')
                                          ELSE core.fn_ui_tpl('core.rollout.fix_offer', jsonb_build_object('n', jsonb_array_length(v_fix))) END),
            'buttons', jsonb_build_array(jsonb_build_object('text_key', 'core.handoff.btn_go', 'data', 'handoff:' || p_domain || ':' || v_max || ':fix')),
            'latch', v_fix->0, 'latches', v_fix)));
    END IF;

    -- Schritt 4: Wert-Waechter von draussen
    IF v_sync AND jsonb_array_length(v_plan.watch_candidates) > 0 THEN
        v_key := v_prefix || '4';
        v_state := core.fn_plan_rollout_latch(v_key);
        IF v_state = 'pending' THEN RETURN jsonb_build_object('step', 4, 'loser', true, 'messages', '[]'::jsonb); END IF;
        IF v_state = 'free' THEN
            IF NOT core.fn_should_notify('plan_rollout', v_key, interval '30 minutes') THEN
                RETURN jsonb_build_object('step', 4, 'loser', true, 'messages', '[]'::jsonb);
            END IF;
            RETURN jsonb_build_object('step', 4, 'messages', jsonb_build_array(jsonb_build_object(
                'msg', jsonb_build_array(jsonb_build_object('kind', 'tpl', 'value', 'core.rollout.watch_offer')),
                'buttons', jsonb_build_array(jsonb_build_object('text_key', 'core.rollout.btn_watch', 'data', 'plan:watch:' || p_domain || ':' || v_plan.version)),
                'memory_agent', v_adv.advisor_agent,
                'latch', jsonb_build_object('source', 'plan_rollout', 'key', v_key))));
        END IF;
        SELECT n.last_fired_at INTO v_at FROM core.notification_state n WHERE n.source = 'plan_rollout' AND n.key = v_key;
        IF v_at > now() - make_interval(hours => v_gap) THEN
            RETURN jsonb_build_object('step', 4, 'wait', true, 'messages', '[]'::jsonb);
        END IF;
    END IF;

    -- Schritt 5: Schluss, nur Haushaltsplan
    IF v_scope = 'per_user' THEN RETURN jsonb_build_object('step', NULL, 'messages', '[]'::jsonb); END IF;
    v_key := v_prefix || '5';
    v_state := core.fn_plan_rollout_latch(v_key);
    IF v_state = 'pending' THEN RETURN jsonb_build_object('step', 5, 'loser', true, 'messages', '[]'::jsonb); END IF;
    IF v_state = 'done' THEN RETURN jsonb_build_object('step', NULL, 'messages', '[]'::jsonb); END IF;

    v_buttons := '[]'::jsonb;
    v_latches := '[]'::jsonb;
    v_off := COALESCE(core.fn_config_get('core', 'cron_enable', 'drift_check'), 'false') <> 'true'
          OR COALESCE(core.fn_config_get('core', 'cron_enable', 'plan_review'), 'false') <> 'true';
    SELECT count(*) INTO v_shown FROM core.notification_state n
     WHERE n.source = 'plan_rollout' AND n.state = 'fired' AND (n.expires_at IS NULL OR n.expires_at > now()) AND n.key LIKE p_domain || ':household:watch_offer:%';
    IF v_off AND v_shown < 2 THEN
        v_buttons := v_buttons || jsonb_build_object('text_key', 'core.rollout.btn_watch_on', 'data', 'watch:on:' || p_domain || ':' || v_plan.version);
        v_slot := v_shown + 1;
        v_latches := v_latches || jsonb_build_object('source', 'plan_rollout', 'key', p_domain || ':household:watch_offer:' || v_slot);
    END IF;
    v_chat := core.fn_person_chat_id(p_person);
    v_share := core.fn_plan_share_preview(p_domain, v_plan.version, v_chat);
    IF (v_share->>'shareable')::boolean IS TRUE THEN
        v_buttons := v_buttons || jsonb_build_object('text_key', 'core.plan_share.btn_inform', 'data', 'plan:share:' || p_domain || ':' || v_plan.version);
    END IF;
    IF jsonb_array_length(v_buttons) = 0 THEN RETURN jsonb_build_object('step', NULL, 'messages', '[]'::jsonb); END IF;
    IF NOT core.fn_should_notify('plan_rollout', v_key, interval '30 minutes') THEN
        RETURN jsonb_build_object('step', 5, 'loser', true, 'messages', '[]'::jsonb);
    END IF;
    IF jsonb_array_length(v_latches) > 0 THEN
        PERFORM core.fn_should_notify('plan_rollout', v_latches->0->>'key', interval '30 minutes');
    END IF;
    v_latches := jsonb_build_array(jsonb_build_object('source', 'plan_rollout', 'key', v_key)) || v_latches;
    RETURN jsonb_build_object('step', 5, 'messages', jsonb_build_array(jsonb_build_object(
        'msg', jsonb_build_array(jsonb_build_object('kind', 'tpl', 'value', 'core.rollout.finish')),
        'buttons', v_buttons,
        'latch', v_latches->0, 'latches', v_latches)));
END;
$$;
