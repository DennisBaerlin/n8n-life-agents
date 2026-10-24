-- ============================================================
-- career.fn_advisor_review (WS-1 — Review-fn der Career-Advisor-Domaene, MINIMAL)
--   Erfuellt den generischen Engine-Vertrag fn(text,jsonb)->jsonb { alerts:[…], digest:{…} } (WS2):
--   der Core-Wrapper core.fn_advisor_review_evaluate dispatcht hierher, latcht je alert ueber metric_key
--   (geteilte core.notification_state, source='advisor:career') und reicht den digest ungelatcht durch.
--   Jeder alert traegt `msg` = [tpl…], der digest `lines` = [tpl…] (Textkatalog Phase C, Form wie finance:
--   career.advisor.*-Keys + typisierte Werte) — die generischen Core-Crons rendern nur die Struktur.
--
--   Metriken: Plan-Staleness (Soll-Plan ueberfaellig) + WS-3 Skill-Gap (career.fn_skill_gap: Soll
--   target_roles[].required_skills[] vs Ist career_profile.skills[]) -> EIN gelatchter singleton-Alert
--   metric_key='skill_gaps' (Owner-Wahl "ruhig": feuert beim Auftauchen, still solange Luecken
--   bestehen — auch wenn die Zahl waechst —, re-armt erst bei gap_count=0). Career-Ist ist weich/selbst-
--   berichtet -> kein harter Soll-Ist-Drift wie bei finance. career.-qualifiziert (der Wrapper
--   fn_advisor_review_evaluate pinnt nur pg_catalog). Ueberskill = KEINE Luecke (hoechstens Digest-Notiz).
--
--   ⚠️ DARF NIE RAISEn: der Drift-Cron wertet ALLE Advisor in EINER materialisierten CTE aus -> eine
--   Exception hier kippt auch den finance-Lauf. Fehlt der Plan/das Profil -> {alerts:[], digest:{lines}}
--   ohne Crash (alle Datums-/Cast-Pfade defensiv geguarded). Der Core-Wrapper faengt nur eine FEHLENDE
--   fn ab, NICHT ein RAISE INNERHALB.
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_advisor_review.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_advisor_review(p_domain text, p_person_id text DEFAULT NULL, p_observations jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_owner       TEXT;   -- P2a: per-Person-Anker (p_person_id, sonst Owner-Fallback); per_user-Reads am Suffix
    v_plan        JSONB;
    v_profile     JSONB;
    v_alerts      JSONB := '[]'::jsonb;
    v_stale_days  NUMERIC;
    v_last_conf   TEXT;
    v_age_days    NUMERIC;
    v_role        TEXT;
    v_target      TEXT;
    v_lines       JSONB;
    -- WS-3 Skill-Gap
    v_gap         JSONB;
    v_gap_count   INT;
    v_blk         INT;
    v_ptitle      TEXT;
    v_pgrole      JSONB;
    v_primary     INT;
    v_gitems      JSONB;
    v_g           JSONB;
    v_more        INT;
BEGIN
    -- P2a: career_planning + career_profile sind per_user (Name-Suffix '<base>__<pid>'). Der GETEILTE Review-
    -- Wrapper core.fn_advisor_review_evaluate reicht den p_person_id jetzt UNIFORM durch (Person-Faecherung); die
    -- P2b-Cron-Schleife ruft pro Person mit gesetztem p_person_id. p_person_id IS NULL (heutige 1-Arg-Cron-Aufrufe)
    -- -> Owner-Fallback via agent.fn_owner_person_id() (LIMIT 1, RAISE-frei) = byte-gleiches P0c-Verhalten. Kein
    -- Owner / kein per-Person-Doc -> COALESCE auf den Basis-Namen (post-Migration leer) -> v_plan/v_profile NULL
    -- -> graceful, kein RAISE.
    v_owner := COALESCE(p_person_id, agent.fn_owner_person_id());
    SELECT c.metadata->'facts' INTO v_plan
    FROM agent.core_contexts c WHERE c.name = COALESCE('career_planning__' || v_owner, 'career_planning');
    SELECT c.metadata->'facts' INTO v_profile
    FROM agent.core_contexts c WHERE c.name = COALESCE('career_profile__' || v_owner, 'career_profile');

    -- Tuning-Schwelle (career-eigener Config-Key; Default 365, falls nicht geseedet -> kein Crash)
    BEGIN
        v_stale_days := COALESCE(core.fn_config_get('career', 'advisor', 'career_plan_stale_days')::numeric, 365);
    EXCEPTION WHEN OTHERS THEN
        v_stale_days := 365;
    END;

    -- ---------- (1) Plan-Staleness ----------
    IF v_plan IS NOT NULL AND jsonb_typeof(v_plan) = 'object'
       AND (v_plan->'_meta') ? 'last_confirmed_at' THEN
        v_last_conf := v_plan->'_meta'->>'last_confirmed_at';
        BEGIN
            v_age_days := CURRENT_DATE - v_last_conf::date;
            v_alerts := v_alerts || core.fn_staleness_alert(
                'plan_staleness', 'plan_staleness', v_age_days, v_stale_days,
                jsonb_build_array(core.fn_ui_tpl('career.advisor.plan_stale', jsonb_build_object(
                    'days', core.fn_ui_num(v_age_days), 'threshold', core.fn_ui_num(v_stale_days)))));
        EXCEPTION WHEN OTHERS THEN NULL;  -- kaputtes Datum -> Metrik still ausgelassen, kein Crash
        END;
    END IF;

    -- ---------- (1b) Skill-Gap (deterministisch; Soll required_skills[] vs Ist skills[]) ----------
    -- career.fn_skill_gap rechnet die Luecke (DB rechnet, nicht das LLM); career.-qualifiziert (der Wrapper
    -- pinnt nur pg_catalog). EIN singleton-Alert metric_key='skill_gaps' (Owner-Wahl "ruhig").
    -- Der Alert-Text versoehnt die Render-Zeile (nur primaere Rolle) mit der Gesamt-Zahl ueber ALLE Rollen.
    -- P0c: rechnet wieder direkt (v_plan/v_profile am Owner-Suffix gelesen) -> der P0b-Suspend-Guard ist weg.
    v_gap := career.fn_skill_gap(v_plan, v_profile);
    v_gap_count := COALESCE((v_gap->>'gap_count')::int, 0);
    IF v_gap_count > 0 THEN
        v_blk     := COALESCE((v_gap->>'blocker_gap_count')::int, 0);
        v_ptitle  := v_plan->'target_roles'->0->>'title';   -- primaere Ziel-Rolle
        SELECT r INTO v_pgrole FROM jsonb_array_elements(v_gap->'roles') r WHERE r->>'title' = v_ptitle LIMIT 1;
        v_primary := 0;   -- 0 bis eine primaere Gap-Rolle gefunden ist (sonst zaehlt der "weitere Ziele"-Zusatz doppelt)
        v_gitems  := '[]'::jsonb;
        IF v_pgrole IS NOT NULL THEN
            v_primary := COALESCE(jsonb_array_length(v_pgrole->'missing'), 0)
                       + COALESCE(jsonb_array_length(v_pgrole->'weak'), 0);
            FOR v_g IN
                SELECT z.x FROM (
                    SELECT m AS x, COALESCE((m->>'is_blocker')::boolean, false) AS blk, 0 AS ord
                    FROM jsonb_array_elements(v_pgrole->'missing') m
                    UNION ALL
                    SELECT w, COALESCE((w->>'is_blocker')::boolean, false), 1
                    FROM jsonb_array_elements(v_pgrole->'weak') w
                ) z ORDER BY z.blk DESC, z.ord LIMIT 3
            LOOP
                -- Pflicht-Skill als eigener Text-Verweis (Marker sprachabhaengig), sonst der Skill-Name (Daten)
                v_gitems := v_gitems || jsonb_build_array(
                    CASE WHEN COALESCE((v_g->>'is_blocker')::boolean, false)
                         THEN core.fn_ui_tpl('career.advisor.skill_blocker', jsonb_build_object('name', v_g->>'name'))
                         ELSE to_jsonb(v_g->>'name') END);
            END LOOP;
        END IF;
        v_more := v_primary - jsonb_array_length(v_gitems);
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'skill_gaps',
            'kind',       'skill_gap',
            'label',      'skill_gaps',
            'value',      v_gap_count,
            'msg',        jsonb_build_array(
                              core.fn_ui_tpl(CASE WHEN v_blk > 0 THEN 'career.advisor.skill_gaps_blockers'
                                                  ELSE 'career.advisor.skill_gaps' END,
                                  jsonb_build_object('count', core.fn_ui_num(v_gap_count), 'blockers', core.fn_ui_num(v_blk))),
                              CASE WHEN v_pgrole IS NOT NULL AND jsonb_array_length(v_gitems) > 0
                                   THEN core.fn_ui_tpl(CASE WHEN v_more > 0 THEN 'career.advisor.skill_gaps_primary_more'
                                                            ELSE 'career.advisor.skill_gaps_primary' END,
                                            jsonb_build_object('role', v_ptitle, 'more', core.fn_ui_num(v_more),
                                                               'skills', jsonb_build_object('kind', 'list', 'value', v_gitems))) END,
                              -- "weitere Ziele"-Zusatz NUR wenn eine primaere Gap-Rolle gezeigt wurde (sonst nennt der
                              -- Hauptsatz schon die Gesamtzahl -> kein Doppelzaehlen; Cold-Eyes A1)
                              CASE WHEN v_pgrole IS NOT NULL AND v_gap_count > v_primary
                                   THEN core.fn_ui_tpl('career.advisor.skill_gaps_other',
                                            jsonb_build_object('n', core.fn_ui_num(v_gap_count - v_primary))) END,
                              core.fn_ui_tpl('career.advisor.skill_gaps_cta')));
    END IF;

    -- ---------- (2) Digest (Quartals-Review, ungelatcht durchgereicht) ----------
    -- P0c: v_profile ist der Owner-Per-Person-Read -> v_role lebt wieder ("Aktuelle Rolle"-Digest-Zeile restauriert).
    v_role   := v_profile->>'current_title';
    v_target := v_plan->'target_roles'->0->>'title';
    -- Digest als Zeilen-STRUKTUR (Textkatalog Phase C, Form wie finance: tpl | null = Leerzeile); entfallene
    -- Zeilen (keine Rolle/Timeline/Luecke) bleiben draussen.
    IF v_plan IS NULL THEN
        v_lines := jsonb_build_array(core.fn_ui_tpl('career.advisor.digest_no_plan'));
    ELSE
        SELECT COALESCE(jsonb_agg(l ORDER BY o), '[]'::jsonb) INTO v_lines FROM (VALUES
            (1, core.fn_ui_tpl('career.advisor.digest_title')),
            (2, CASE WHEN v_role IS NOT NULL THEN core.fn_ui_tpl('career.advisor.digest_role', jsonb_build_object('role', v_role)) END),
            (3, CASE WHEN v_target IS NOT NULL THEN core.fn_ui_tpl('career.advisor.digest_target', jsonb_build_object('role', v_target)) END),
            (4, CASE WHEN v_plan->>'timeline_years' IS NOT NULL
                     THEN core.fn_ui_tpl('career.advisor.digest_timeline', jsonb_build_object('years', v_plan->>'timeline_years')) END),
            -- WS-3: Skill-Luecken-Aufschluesselung (ungelatcht im Digest) + Ueberskill-Randnotiz
            (5, CASE WHEN COALESCE((v_gap->>'gap_count')::int, 0) > 0
                     THEN core.fn_ui_tpl(CASE WHEN COALESCE((v_gap->>'blocker_gap_count')::int, 0) > 0
                                              THEN 'career.advisor.digest_gaps_blockers' ELSE 'career.advisor.digest_gaps' END,
                              jsonb_build_object('n', core.fn_ui_num((v_gap->>'gap_count')::numeric),
                                                 'blockers', core.fn_ui_num((v_gap->>'blocker_gap_count')::numeric))) END),
            (6, CASE WHEN COALESCE((v_gap->>'overskill_count')::int, 0) > 0
                     THEN core.fn_ui_tpl('career.advisor.digest_overskill',
                              jsonb_build_object('n', core.fn_ui_num((v_gap->>'overskill_count')::numeric))) END)
        ) x(o, l) WHERE l IS NOT NULL;
    END IF;

    RETURN jsonb_build_object(
        'ok',     true,
        'alerts', v_alerts,
        'digest', jsonb_build_object('lines', v_lines));
END;
$$;
