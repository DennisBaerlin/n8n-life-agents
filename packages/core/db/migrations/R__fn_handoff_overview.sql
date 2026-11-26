-- ============================================================
-- core.fn_handoff_latch_key(p_domain, p_chat_id, p_max) — Merker-Schluessel einer Uebergabe-Liste (plan_rollout)
--   '<domain>:<household|person_id>:<version>:handoff:<max_task_id>'; version = Version des gueltigen Plans dieser Domain
--   und Person (0 ohne gueltigen Plan), Person nur bei per_user (core.fn_handoff_person). Damit gilt "einmal je
--   veroeffentlichter Version": eine Liste, die waehrend eines Entwurfs gezeigt wurde, haelt die Liste nach dem
--   Veroeffentlichen nicht zurueck. Die eine Adresse fuer core.fn_handoff_overview (latch_key), core.fn_handoff_overview_mark
--   und core.fn_advisor_resume_due. NULL bei leerer Domain, fehlendem max oder unaufgeloester per_user-Person. Nur lesend.
--   Tests: tests/db/core/test_fn_handoff_overview_mark.sql, tests/db/core/test_fn_plan_rollout_next.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_latch_key(p_domain text, p_chat_id text, p_max int)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pid text;
    v_ver int;
BEGIN
    IF COALESCE(p_domain, '') = '' OR p_max IS NULL THEN RETURN NULL; END IF;
    IF COALESCE((SELECT cs.scope FROM core.context_scopes cs JOIN core.advisors a ON a.plan_context = cs.context_name
                  WHERE a.domain = p_domain), 'household') = 'per_user' THEN
        v_pid := core.fn_handoff_person(p_chat_id);
        IF v_pid IS NULL THEN RETURN NULL; END IF;
    END IF;
    SELECT ap.version INTO v_ver FROM agent.advisor_plans ap
     WHERE ap.domain = p_domain AND ap.person_id IS NOT DISTINCT FROM v_pid AND ap.status = 'active';
    RETURN p_domain || ':' || COALESCE(v_pid, 'household') || ':' || COALESCE(v_ver, 0) || ':handoff:' || p_max;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_latch_key(text, text, int) FROM public;

-- ============================================================
-- core.fn_handoff_list_shown_at(p_key) — wann eine Liste mit diesen Eintraegen schon festgeschrieben gezeigt wurde
--   p_key = latch_key (core.fn_handoff_latch_key). Aufgaben-ids wachsen nur; eine Liste bis max M deckt jede offene Liste
--   derselben Person, Domain und Plan-Version mit max <= M ab (eine liegen gebliebene Aufgabe loest keine neue Liste aus,
--   eine neu vereinbarte mit hoeherer id schon). Rueckgabe: last_fired_at des juengsten deckenden, festgeschriebenen Merkers
--   (source plan_rollout, state fired, ohne Frist), sonst NULL. Nur lesend. Tests: tests/db/core/test_fn_plan_rollout_next.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_list_shown_at(p_key text)
RETURNS timestamptz
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT max(n.last_fired_at)
      FROM core.notification_state n
     WHERE p_key ~ ':handoff:[0-9]{1,9}$'
       AND n.source = 'plan_rollout' AND n.state = 'fired' AND n.expires_at IS NULL
       AND n.key ~ ':handoff:[0-9]{1,9}$'
       AND left(n.key, length(n.key) - length(substring(n.key FROM ':handoff:[0-9]+$')))
           = left(p_key, length(p_key) - length(substring(p_key FROM ':handoff:[0-9]+$')))
       AND substring(n.key FROM ':handoff:([0-9]+)$')::int >= substring(p_key FROM ':handoff:([0-9]+)$')::int;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_list_shown_at(text) FROM public;

-- ============================================================
-- core.fn_handoff_overview(p) — offene vereinbarte Plan-Aufgaben einer Person fuer die Uebersicht [Jetzt eintragen]
--   p: { domain (Pflicht, Plan-Domain), chat_id (Identitaet, core.fn_handoff_person), via (optional: 'rollout' = Schritt 1
--   der gefuehrten Abfolge nach dem Veroeffentlichen, sonst der Berater) }.
--   Rueckgabe {count, max_task_id (NULL ohne offene), latch_key (core.fn_handoff_latch_key; NULL ohne offene), effect,
--   items: [text, ...] in Anlage-Reihenfolge, msg: Text-Struktur
--   core.handoff.overview (core.fn_ui_tpl) mit list (nummeriert) und why (warum die Liste jetzt kommt: rollout ->
--   core.handoff.why_rollout {n} bzw. why_rollout_one, sonst core.handoff.why_advisor)}. Kein "offen seit" und kein
--   "geht auch spaeter": die Liste ist der Pflichtschritt nach dem Veroeffentlichen, keine Erinnerung.
--   effect = Folge-Zeile (Text-Struktur core.handoff.effect {n} bzw. effect_one) nur mit offenen Punkten und wenn die Paket-fn
--   core.advisors.entry_effects_fn(domain) accounts > 0 meldet (Konten mit Warnung, die nur an fehlenden Eintraegen haengt);
--   sonst NULL. Fehlt oder wirft die fn, entfaellt die Zeile. Schritt 1 der Abfolge haengt sie als zweite Nachrichtenzeile an.
--   Eine Adresse fuer beide Sender: agent.tool_send_handoff_overview und Schritt 1 von
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
    v_efn   regprocedure;
    v_eff   jsonb;
    v_acc   int;
    v_ttl   int := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
BEGIN
    SELECT jsonb_build_object('count', count(*), 'max_task_id', max(t.id),
                              'items', COALESCE(jsonb_agg(t.text ORDER BY t.id), '[]'::jsonb))
      INTO v_out
      FROM agent.handoff_tasks t
     WHERE t.domain = COALESCE(p->>'domain', '') AND t.person_id = v_pid
       AND (t.status = 'open' OR (t.status = 'working' AND t.claimed_at < now() - make_interval(mins => v_ttl)));
    IF (v_out->>'count')::int > 0 THEN
        v_efn := to_regprocedure((SELECT a.entry_effects_fn FROM core.advisors a WHERE a.domain = p->>'domain') || '(text)');
        IF v_efn IS NOT NULL THEN
            BEGIN
                EXECUTE format('SELECT %s($1)', v_efn::regproc) INTO v_eff USING p->>'domain';
                v_acc := CASE WHEN jsonb_typeof(v_eff->'accounts') = 'number' THEN (v_eff->>'accounts')::numeric::int END;
            EXCEPTION WHEN OTHERS THEN
                v_acc := NULL;
            END;
        END IF;
    END IF;
    RETURN v_out || jsonb_build_object(
      'effect', CASE WHEN v_acc = 1 THEN core.fn_ui_tpl('core.handoff.effect_one')
                     WHEN v_acc > 1 THEN core.fn_ui_tpl('core.handoff.effect', jsonb_build_object('n', v_acc)) END,
      'latch_key', core.fn_handoff_latch_key(p->>'domain', p->>'chat_id', (v_out->>'max_task_id')::int),
      'msg', core.fn_ui_tpl('core.handoff.overview', jsonb_build_object(
        'list', (SELECT string_agg(i || '. ' || (x #>> '{}'), E'\n' ORDER BY i) FROM jsonb_array_elements(v_out->'items') WITH ORDINALITY AS e(x, i)),
        'why', CASE WHEN p->>'via' = 'rollout' AND (v_out->>'count')::int = 1 THEN core.fn_ui_tpl('core.handoff.why_rollout_one')
                    WHEN p->>'via' = 'rollout' THEN core.fn_ui_tpl('core.handoff.why_rollout', jsonb_build_object('n', (v_out->>'count')::int))
                    ELSE core.fn_ui_tpl('core.handoff.why_advisor') END)));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_overview(jsonb) FROM public;
