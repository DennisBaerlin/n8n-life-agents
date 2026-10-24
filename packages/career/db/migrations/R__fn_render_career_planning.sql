-- ============================================================
-- career.fn_render_career_planning (WS-1 — Render des career_planning-Sidecars, Header-only)
--   Liefert NUR den autoritativen Fakten-HEADER des advisor-gepflegten 'career_planning'-Sidecars
--   (Ziel-Rollen, Ziel-Branchen, Umstiegs-Timeline). Vorbild finance.fn_render_plan_facts. Die Engine
--   core.fn_fetch_context wrappt Banner + Header + _meta + Prosa. UNIFORME Signatur fn(text)->text.
--   ABLEITUNG render-at-fetch, NIE gespeichert: "angepeilter Umstieg ~<Jahr>" aus timeline_years + heute
--   (kein gespeichertes target_year — die Denylist sperrt es). Die Skill-Luecken-Zeile der
--   primaeren Ziel-Rolle (WS-3) rendert career.fn_skill_gap render-at-fetch (Soll required_skills[] vs Ist
--   career_profile.skills[]). WS-4: die Stellen-Nachfrage-Zeile rendert career.fn_market_trend (Posting-Trend,
--   render-at-fetch). WS-5: die Runway-Zeile rendert career.fn_runway (cross-paket finance->career, Doppel-Guard
--   + graceful NULL). ALLE career.*/agent.*/finance.*-Referenzen schema-qualifiziert (DEFINER-Pin via fn_fetch_context).
--   RUECKGABE: Header-Text ODER NULL (kein facts-Sidecar -> nur Prosa).
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_render_career_planning.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_render_career_planning(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_facts    JSONB;
    v_lines    TEXT[] := '{}';
    v_roles    TEXT[] := '{}';
    v_inds     TEXT[] := '{}';
    v_role     JSONB;
    v_ind      JSONB;
    v_tl       NUMERIC;
    v_prof     JSONB;
    v_pid      TEXT;   -- P0c: person_id aus dem suffigierten p_name (career_planning__<pid>) abgeleitet
    v_gap      JSONB;
    v_grole    JSONB;
    v_ptitle   TEXT;
    v_gap_items TEXT[];
    v_g        JSONB;
    v_cnt      INT;
    v_more     INT;
    v_mtrend   JSONB;   -- WS-4 Stellen-Nachfrage-Trend (career.fn_market_trend, render-at-fetch)
    v_rw       JSONB;   -- WS-5 Runway (career.fn_runway, cross-paket finance->career, render-at-fetch)
BEGIN
    SELECT c.metadata->'facts' INTO v_facts FROM agent.core_contexts c WHERE c.name = p_name;
    IF v_facts IS NULL OR jsonb_typeof(v_facts) <> 'object' OR v_facts = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    -- Ziel-Rollen (max 3, kompakt; optional Zielgehalt)
    IF jsonb_typeof(v_facts->'target_roles') = 'array' THEN
        FOR v_role IN SELECT * FROM jsonb_array_elements(v_facts->'target_roles') LIMIT 3 LOOP
            v_roles := v_roles || (COALESCE(v_role->>'title','?')
                || CASE WHEN v_role ? 'salary_expectation_eur'
                        THEN ' (~' || (v_role->>'salary_expectation_eur') || ' €)' ELSE '' END);
        END LOOP;
        IF array_length(v_roles, 1) > 0 THEN
            v_lines := v_lines || ('Ziel-Rolle(n): ' || array_to_string(v_roles, ', '));
        END IF;
    END IF;

    -- Ziel-Branchen (Strings oder { name })
    IF jsonb_typeof(v_facts->'target_industries') = 'array' THEN
        FOR v_ind IN SELECT * FROM jsonb_array_elements(v_facts->'target_industries') LOOP
            v_inds := v_inds || CASE WHEN jsonb_typeof(v_ind) = 'object'
                                     THEN COALESCE(v_ind->>'name','?') ELSE trim(both '"' from v_ind::text) END;
        END LOOP;
        IF array_length(v_inds, 1) > 0 THEN
            v_lines := v_lines || ('Zielbranche(n): ' || array_to_string(v_inds, ', '));
        END IF;
    END IF;

    -- Timeline + Ableitung "angepeilter Umstieg ~Jahr" (render-at-fetch)
    IF v_facts ? 'timeline_years' AND jsonb_typeof(v_facts->'timeline_years') = 'number' THEN
        v_tl := (v_facts->>'timeline_years')::numeric;
        v_lines := v_lines || ('Umstiegs-Timeline: ' || (v_facts->>'timeline_years') || ' Jahre'
            || CASE WHEN v_tl >= 0
                    THEN ' (angepeilter Umstieg ~' || to_char(CURRENT_DATE + make_interval(years => floor(v_tl)::int), 'YYYY') || ')'
                    ELSE '' END);
    END IF;

    -- WS-3: Skill-Luecken-Zeile der PRIMAEREN Ziel-Rolle (target_roles[0]); render-at-fetch, nichts gespeichert.
    -- career.* + agent.* schema-qualifiziert (DEFINER-Pin pg_catalog,agent,core via fn_fetch_context, KEIN career).
    -- P0c: career_planning ist per_user -> p_name ist der PHYSISCHE, suffigierte Name (career_planning__<pid>,
    -- fn_fetch_context USING v_physical). career_profile derselben Person liegt unter demselben Suffix -> die
    -- person_id aus p_name ableiten (greedy .+ -> person_id mit eigenen '__' bleibt intakt) und career_profile__<pid>
    -- lesen. KEIN Basis-/scope-Guard mehr (der P0b-Interim ist mit P0c weg) -> die Skill-Luecken-Zeile rendert wieder.
    v_ptitle := v_facts->'target_roles'->0->>'title';
    IF v_ptitle IS NOT NULL THEN
        v_pid := substring(p_name from '^career_planning__(.+)$');
        SELECT c.metadata->'facts' INTO v_prof FROM agent.core_contexts c
        WHERE c.name = CASE WHEN v_pid IS NOT NULL THEN 'career_profile__' || v_pid ELSE 'career_profile' END;
        v_gap := career.fn_skill_gap(v_facts, v_prof);
        SELECT r INTO v_grole FROM jsonb_array_elements(v_gap->'roles') r WHERE r->>'title' = v_ptitle LIMIT 1;
        IF v_grole IS NOT NULL
           AND (jsonb_array_length(v_grole->'missing') + jsonb_array_length(v_grole->'weak')) > 0 THEN
            v_gap_items := '{}';
            -- Blocker zuerst (missing+weak gemischt), max 3
            FOR v_g IN
                SELECT z.x FROM (
                    SELECT m AS x, COALESCE((m->>'is_blocker')::boolean, false) AS blk, 0 AS ord
                    FROM jsonb_array_elements(v_grole->'missing') m
                    UNION ALL
                    SELECT w, COALESCE((w->>'is_blocker')::boolean, false), 1
                    FROM jsonb_array_elements(v_grole->'weak') w
                ) z ORDER BY z.blk DESC, z.ord LIMIT 3
            LOOP
                v_gap_items := v_gap_items || (
                    (v_g->>'name')
                    || CASE WHEN v_g ? 'have'   -- 'have' nur bei weak -> Ist->Soll; sonst missing -> Soll, fehlt
                            THEN ' (' || COALESCE(v_g->>'have', '?') || '->' || COALESCE(v_g->>'required', '?') || ')'
                            ELSE ' (' || COALESCE(v_g->>'required', 'offen') || ', fehlt)' END
                    || CASE WHEN COALESCE((v_g->>'is_blocker')::boolean, false) THEN ' [Pflicht]' ELSE '' END);
            END LOOP;
            v_cnt  := jsonb_array_length(v_grole->'missing') + jsonb_array_length(v_grole->'weak');
            v_more := v_cnt - COALESCE(array_length(v_gap_items, 1), 0);
            v_lines := v_lines || ('Skill-Lücken (Ziel ' || v_ptitle || '): ' || array_to_string(v_gap_items, ' · ')
                || CASE WHEN v_more > 0 THEN '; +' || v_more || ' weitere' ELSE '' END);
        END IF;
    END IF;

    -- WS-4: Stellen-Nachfrage-Zeile (Posting-Count + Trend der primaeren Rolle) via career.fn_market_trend
    -- render-at-fetch (DB rechnet, nichts gespeichert). career.* schema-qualifiziert (DEFINER-Pin pg_catalog,
    -- agent,core via fn_fetch_context; der Renderer laeuft als dessen Owner -> liest career.market_signals).
    v_mtrend := career.fn_market_trend(v_facts);
    IF v_mtrend IS NOT NULL AND (v_mtrend->>'count') IS NOT NULL THEN
        v_lines := v_lines || ('Stellen-Nachfrage: ' || (v_mtrend->>'count') || ' offene Stellen'
            || COALESCE(' für ' || (v_mtrend->>'location'), '')
            || CASE WHEN (v_mtrend->>'trend_pct') IS NOT NULL
                    THEN ', Trend ' || CASE WHEN (v_mtrend->>'trend_pct')::numeric >= 0 THEN '+' ELSE '' END
                         || (v_mtrend->>'trend_pct') || '%'
                    ELSE '' END);
    END IF;

    -- WS-5: Runway-Zeile ("kann ich mir den Jobwechsel leisten?") — cross-paket finance->career, render-at-fetch.
    -- career.fn_runway doppel-guardet das OPTIONALE finance-Paket (fn_package_active + to_regprocedure) und
    -- liefert NULL, wenn finance fehlt/inaktiv -> die Zeile entfaellt graceful (kein Crash). finance.*/core.*
    -- in fn_runway schema-qualifiziert (DEFINER-Pin pg_catalog,agent,core via fn_fetch_context; der Renderer
    -- laeuft als dessen Owner=Superuser -> liest finance.* OHNE neuen Grant, Oberflaeche A der WS-5-arch-challenge).
    v_rw := career.fn_runway(v_facts);
    IF v_rw IS NOT NULL THEN
        v_lines := v_lines || ('Runway: '
            || CASE WHEN v_rw->>'runway_months' IS NOT NULL
                    THEN (v_rw->>'runway_months') || ' Monate (Probezeit ' || (v_rw->>'probation_months') || ' Mon. '
                         || CASE WHEN (v_rw->>'covers')::boolean
                                 THEN 'gedeckt)'
                                 ELSE 'NICHT gedeckt - Lücke '
                                      || ((v_rw->>'probation_months')::int - (v_rw->>'runway_months')::int)::text || ' Mon.)' END
                    ELSE 'unbegrenzt (Notfall-Einkommen deckt die Ausgaben)' END
            -- WP-3c: fehlt fuer ein Fremdwaehrungs-Cash-Konto der Wechselkurs, ist es NICHT in cash_eur -> die
            -- Runway ist zu optimistisch. Sichtbar melden statt still unterzaehlen (Owner-Prinzip).
            || CASE WHEN (v_rw->>'has_fx_gap')::boolean
                    THEN E'\n  ⚠ Hinweis: ein Fremdwährungs-Konto ohne aktuellen Wechselkurs ist noch NICHT '
                         || 'eingerechnet - die tatsächliche Liquidität (und damit die Runway) liegt höher.'
                    ELSE '' END);
    END IF;

    IF array_length(v_lines, 1) IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN '- ' || array_to_string(v_lines, E'\n- ');
END;
$$;
