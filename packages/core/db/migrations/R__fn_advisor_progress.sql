-- ============================================================
-- core.fn_advisor_progress(p) — Stand des Plan-Gespraechs einer Domaene fuer einen Chat (READ)
--   Die eine Adresse fuer "wo stehen wir": Kontext-Kopf des Beraters, Koepfe der Karten (Teil k von m, Punkt k von n,
--   Eintrag k von n), Menue ("fortsetzen, Teil 4 von 9", "noch 2 Eintraege"), Erinnerungstexte, state enter
--   und part/parts_total in core.fn_advisor_plan_status.
--   Teile/Etappen aus core.fn_advisor_parts; ein Teil ist fertig, wenn sein Abschnitt im Entwurf (ohne Entwurf im aktiven
--   Plan) mindestens ein Thema oder einen Abschnitts-Text hat (ein Alt-Text allein zaehlt nicht).
--   Personen-Regel wie core.fn_advisor_plan_status (household -> Haushalts-Plan, per_user -> der Absender; aus einer Frei-SQL-
--   Sitzung (core.fn_is_free_sql_session) kein per_user-Plan, Muster core.fn_advisor_read_plan).
--   phase: none (kein Plan) | talk (Entwurf, Teile offen) | check (alle Teile da, Schlusspruefung nicht abgeschlossen) |
--     publish (letzter Durchgang ohne offene Zeile: kein Punkt hat Themen geaendert oder advisor.check_max_passes erreicht) |
--     enter (veroeffentlicht, vereinbarte Eintraege offen) | done.
--   mode: existing = es gibt einen aktiven Plan oder der Entwurf traegt einen Alt-Text (legacy_content), sonst fresh.
--   check {pass, total, done}: Prüfpunkte (Art finding ohne Uebersicht) des letzten Durchgangs am Entwurf.
--   handoffs {total, done, deferred}: vereinbarte Aufgaben der Domaene seit Anlage der aktuellen Plan-Zeile; total ohne cancelled
--     und ohne deferred (zurueckgestellt wartet auf ein Update, keine Aufgabe des Nutzers), deferred = deren Zahl.
--   rollout_next: 'check', wenn die Gefuehrte Abfolge (core.fn_plan_rollout_next) den Pruef-Schritt anbieten wird: kein Entwurf, aktiver
--     Plan, Absender bekommt Schritte (Haushaltsplan nur der Owner), die Schritte davor sind durch ([Plan durchsehen] erledigt oder nicht
--     verlangt, kein Eintrag der Person open/working, kein nachholbarer Eintrag mit freiem fix-Merker) und ein erledigter Altbestand ohne
--     Provenienz (core.fn_handoff_register row_kind legacy) hat noch keinen festgeschriebenen Pruef-Merker; sonst NULL. Ein Paket-Schritt
--     (core.advisors.rollout_fn) kann davor kommen, ein Entwurf ueber der Stale-Grenze zaehlt hier noch als Entwurf (beides bewusst
--     nicht nachgebaut: der Kopf meldet dann hoechstens nichts). Der Kontext-Kopf zeigt ihn, damit der Berater keine Frage stellt,
--     die den Schritt zurueckhaelt (Laufende im Orchestrator).
--   stages [{key, parts_total, parts_done, done}], stage_current (Etappe des naechsten offenen Teils, sonst die letzte),
--   stage_boundary (der naechste offene Teil ist der erste einer Etappe und die vorige ist fertig; bei einer Etappe nie),
--   current = der naechste offene Teil {n, stage, section_key, annex?, slot?} (erstes offenes in Folge, kein gespeicherter Fokus),
--   parts [{key, stage, state done|current|open, headline (erstes Thema), annex?, slot?}] in Folge.
--   Eingabe p: {domain, chat_id}. Rueckgabe {ok:true, mode, phase, parts_total, parts_done, current_key, open_points, check,
--   handoffs, rollout_next, stages, stage_current, stage_boundary, current, parts} | {ok:false, reason} (unaufgeloester Absender, fehlende Domaene,
--   persoenlicher Plan aus Frei-SQL).
--   SECURITY DEFINER (liest agent.*), STABLE, search_path gepinnt; EXECUTE core_ro (util_create_core_ro.sql) + Host-Cred.
--   Tests: tests/db/core/test_fn_advisor_progress.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_progress(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain  text := NULLIF(btrim(COALESCE(p->>'domain', '')), '');
    v_chat    text := COALESCE(p->>'chat_id', '');
    v_sender  jsonb;
    v_ctx     text;
    v_target  text;
    v_draft   agent.advisor_plans%ROWTYPE;
    v_active  agent.advisor_plans%ROWTYPE;
    v_state   jsonb;
    v_since   timestamptz;
    v_parts   jsonb;
    v_done    jsonb;
    v_cur     jsonb;
    v_stages  jsonb;
    v_pass    int;
    v_total   int := 0;
    v_ok      int := 0;
    v_openchk boolean := false;
    v_changed boolean := false;
    v_max     int;
    v_phase   text;
    v_mode    text;
    v_h_total int;
    v_h_done  int;
    v_h_def   int;
    v_bound   boolean := false;
    v_prev    text;
    v_next    text;
    v_who     text;
    v_pid     text;
    v_reg     jsonb;
BEGIN
    IF v_domain IS NULL OR NOT core.fn_chat_id_ok(v_chat) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'domain and chat_id are required');
    END IF;
    v_sender := core.fn_chat_person(v_chat);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unresolved_sender');
    END IF;
    v_ctx := COALESCE((SELECT a.plan_context FROM core.advisors a WHERE a.domain = v_domain), v_domain || '_planning');
    IF COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = v_ctx), 'household') = 'per_user' THEN
        -- Frei-SQL (guide/monitor unter core_ro): dort waere die chat_id LLM-gesteuert -> kein fremder persoenlicher Plan.
        IF core.fn_is_free_sql_session() THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'per_user plan not readable from free SQL');
        END IF;
        v_target := v_sender->>'person_id';
    END IF;
    SELECT * INTO v_draft FROM agent.advisor_plans
     WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_target AND status = 'draft';
    SELECT * INTO v_active FROM agent.advisor_plans
     WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_target AND status = 'active';
    v_state := COALESCE(v_draft.interview_state, v_active.interview_state, '{}'::jsonb);
    v_since := COALESCE(v_draft.created_at, v_active.created_at);

    v_parts := core.fn_advisor_parts(v_domain);
    SELECT COALESCE(jsonb_agg(e ORDER BY (e->>'n')::int), '[]'::jsonb) INTO v_done
      FROM jsonb_array_elements(v_parts) e
     WHERE (jsonb_typeof(v_state->(e->>'section_key')->'topics') = 'array' AND jsonb_array_length(v_state->(e->>'section_key')->'topics') > 0)
        OR btrim(COALESCE(v_state->(e->>'section_key')->>'content', '')) <> '';
    SELECT e INTO v_cur FROM jsonb_array_elements(v_parts) e WHERE NOT (v_done @> jsonb_build_array(e))
     ORDER BY (e->>'n')::int LIMIT 1;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('key', s.stage, 'parts_total', s.t, 'parts_done', s.d, 'done', s.t = s.d) ORDER BY s.first_n), '[]'::jsonb)
      INTO v_stages
      FROM (SELECT e->>'stage' AS stage, count(*) AS t, count(*) FILTER (WHERE v_done @> jsonb_build_array(e)) AS d,
                   min((e->>'n')::int) AS first_n
              FROM jsonb_array_elements(v_parts) e GROUP BY e->>'stage') s;
    IF v_cur IS NOT NULL AND jsonb_array_length(v_stages) > 1 THEN
        SELECT e->>'stage' INTO v_prev FROM jsonb_array_elements(v_parts) e WHERE (e->>'n')::int = (v_cur->>'n')::int - 1;
        v_bound := v_prev IS NOT NULL AND v_prev <> v_cur->>'stage'
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_stages) s WHERE s->>'key' = v_prev AND (s->>'done')::boolean);
    END IF;

    IF v_draft.id IS NOT NULL THEN
        SELECT max((c.payload->>'pass')::int) INTO v_pass FROM agent.chat_prompts c
         WHERE c.plan_id = v_draft.id AND c.kind = 'finding' AND c.status <> 'superseded';
        SELECT count(*), count(*) FILTER (WHERE c.status = 'answered'),
               bool_or(c.status IN ('queued', 'open')), bool_or(COALESCE((c.payload->>'changed')::boolean, false))
          INTO v_total, v_ok, v_openchk, v_changed
          FROM agent.chat_prompts c
         WHERE c.plan_id = v_draft.id AND c.kind = 'finding' AND c.status <> 'superseded'
           AND (c.payload->>'pass')::int = v_pass AND c.payload->>'role' IS DISTINCT FROM 'overview';
        v_openchk := COALESCE(v_openchk, false) OR EXISTS (SELECT 1 FROM agent.chat_prompts c
                      WHERE c.plan_id = v_draft.id AND c.kind = 'finding' AND c.status IN ('queued', 'open'));
    END IF;
    v_max := COALESCE(NULLIF(substring(COALESCE(core.fn_config_get('core', 'advisor', 'check_max_passes'), '') FROM '^\s*(\d+)\s*$'), '')::int, 2);

    SELECT count(*) FILTER (WHERE t.status NOT IN ('cancelled', 'deferred')), count(*) FILTER (WHERE t.status = 'done'),
           count(*) FILTER (WHERE t.status = 'deferred')
      INTO v_h_total, v_h_done, v_h_def
      FROM agent.handoff_tasks t
     WHERE t.domain = v_domain AND (v_target IS NULL OR t.person_id = v_target) AND t.created_at >= v_since;

    v_phase := CASE
        WHEN v_draft.id IS NULL AND v_active.id IS NULL THEN 'none'
        WHEN v_draft.id IS NOT NULL AND v_cur IS NOT NULL THEN 'talk'
        WHEN v_draft.id IS NOT NULL AND (v_pass IS NULL OR v_openchk OR (COALESCE(v_changed, false) AND v_pass < v_max)) THEN 'check'
        WHEN v_draft.id IS NOT NULL THEN 'publish'
        WHEN COALESCE(v_h_total, 0) > COALESCE(v_h_done, 0) THEN 'enter'
        ELSE 'done' END;
    -- Vorbedingungen wie core.fn_plan_rollout_next vor dem Pruef-Schritt (Schritt 0, offene Eintraege, fix); die billigen
    -- zuerst, das Register (ruft Paket-fns je Eintrag) nur, wenn ein Altbestand ueberhaupt da ist.
    v_who := COALESCE(v_target, 'household');
    v_pid := COALESCE(v_target, v_sender->>'person_id');
    IF v_draft.id IS NULL AND v_active.id IS NOT NULL
       AND (v_target IS NOT NULL OR v_pid IS NOT DISTINCT FROM agent.fn_owner_person_id())
       AND NOT (v_active.synced_at IS NULL
                AND COALESCE(core.fn_config_get((SELECT a.package FROM core.advisors a WHERE a.domain = v_domain), 'advisor', 'plan_sync_required'), 'false') = 'true')
       AND NOT EXISTS (SELECT 1 FROM agent.handoff_tasks t
                        WHERE t.domain = v_domain AND t.person_id = v_pid AND t.status IN ('open', 'working'))
       AND EXISTS (SELECT 1 FROM agent.handoff_tasks t
                    WHERE t.domain = v_domain AND t.person_id = v_pid AND t.status = 'done' AND t.close_reason IS NULL
                      AND NOT EXISTS (SELECT 1 FROM agent.handoff_tasks f WHERE f.follows_task_id = t.id)) THEN
        v_reg := core.fn_handoff_register(v_domain, v_chat);
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_reg) e
                        WHERE (e->>'possible_now')::boolean
                          AND core.fn_plan_rollout_latch(v_domain || ':' || v_who || ':' || v_active.version || ':fix:' || (e->>'task_id')) <> 'done') THEN
            SELECT 'check' INTO v_next FROM jsonb_array_elements(v_reg) e
             WHERE e->>'row_kind' = 'legacy' AND e->>'status' = 'done'
               AND core.fn_plan_rollout_latch(v_domain || ':' || v_who || ':check:' || (e->>'task_id')) <> 'done'
             LIMIT 1;
        END IF;
    END IF;
    v_mode := CASE WHEN v_active.id IS NOT NULL
                     OR EXISTS (SELECT 1 FROM jsonb_each(CASE WHEN jsonb_typeof(v_draft.interview_state) = 'object' THEN v_draft.interview_state ELSE '{}'::jsonb END) s
                                 WHERE btrim(COALESCE(s.value->>'legacy_content', '')) <> '')
                   THEN 'existing' ELSE 'fresh' END;

    RETURN jsonb_build_object('ok', true, 'mode', v_mode, 'phase', v_phase,
        'parts_total', jsonb_array_length(v_parts), 'parts_done', jsonb_array_length(v_done),
        'current_key', v_cur->>'section_key',
        'open_points', (SELECT count(*) FROM core.fn_plan_open_points(v_state) o WHERE NOT o.resolved),
        'check', jsonb_build_object('pass', COALESCE(v_pass, 0), 'total', COALESCE(v_total, 0), 'done', COALESCE(v_ok, 0)),
        'handoffs', jsonb_build_object('total', COALESCE(v_h_total, 0), 'done', COALESCE(v_h_done, 0), 'deferred', COALESCE(v_h_def, 0)),
        'rollout_next', v_next,
        'stages', v_stages,
        'stage_current', COALESCE(v_cur->>'stage', (SELECT e->>'stage' FROM jsonb_array_elements(v_parts) e ORDER BY (e->>'n')::int DESC LIMIT 1)),
        'stage_boundary', v_bound,
        'current', v_cur,
        'parts', COALESCE((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('key', e->>'section_key', 'stage', e->>'stage',
                      'annex', e->'annex', 'slot', e->'slot',
                      'state', CASE WHEN v_done @> jsonb_build_array(e) THEN 'done' WHEN e = v_cur THEN 'current' ELSE 'open' END,
                      'headline', v_state->(e->>'section_key')->'topics'->0->>'topic')) ORDER BY (e->>'n')::int)
                             FROM jsonb_array_elements(v_parts) e), '[]'::jsonb));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_progress(jsonb) FROM public;

-- ============================================================
-- core.fn_advisor_parts(p_domain) — Hilfs-fn derselben Familie: die Teile eines Plan-Gespraechs in Reihenfolge, mit Etappe (READ)
--   Quelle ist allein core.advisors.stages (Manifest advisors.<domain>.stages, [{key, sections:[key | {key, annex?, slot?}]}]),
--   annex/slot werden durchgereicht; ohne stages eine
--   Etappe 'all' aus den Abschnitts-Keys des Textkatalogs <paket>.plan_section.* (alphabetisch). E2E-Domain -> echte Domain.
--   Rueckgabe jsonb [{n, stage, section_key, annex?, slot?}] (n = 1..m).
--   Tests: tests/db/core/test_fn_advisor_progress.sql, tests/db/core/test_fn_advisor_propose_topics.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_parts(p_domain text)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_dom    text := regexp_replace(COALESCE(p_domain, ''), '^__e2e_(.+)__$', '\1');
    v_stages jsonb;
    v_pkg    text;
BEGIN
    SELECT a.stages, a.package INTO v_stages, v_pkg FROM core.advisors a WHERE a.domain = v_dom;
    IF jsonb_typeof(v_stages) = 'array' THEN
        RETURN COALESCE((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('n', n, 'stage', stage, 'section_key', sk,
                                    'annex', annex, 'slot', slot)) ORDER BY n)
                           FROM (SELECT row_number() OVER (ORDER BY si, ki) AS n, s->>'key' AS stage,
                                        CASE WHEN jsonb_typeof(k) = 'object' THEN k->>'key' ELSE k #>> '{}' END AS sk,
                                        CASE WHEN jsonb_typeof(k) = 'object' THEN k->'annex' END AS annex,
                                        CASE WHEN jsonb_typeof(k) = 'object' THEN k->'slot' END AS slot
                                   FROM jsonb_array_elements(v_stages) WITH ORDINALITY AS x(s, si),
                                        jsonb_array_elements(s->'sections') WITH ORDINALITY AS y(k, ki)) q), '[]'::jsonb);
    END IF;
    v_pkg := COALESCE(v_pkg, 'core');
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('n', n, 'stage', 'all', 'section_key', sk) ORDER BY n)
                       FROM (SELECT row_number() OVER (ORDER BY sk) AS n, sk
                               FROM (SELECT DISTINCT substr(t.key, length(v_pkg) + 15) AS sk FROM core.ui_texts t
                                      WHERE t.package = v_pkg AND t.key ~ ('^' || v_pkg || '\.plan_section\.[a-z0-9_]+$')) d) q), '[]'::jsonb);
END;
$$;
