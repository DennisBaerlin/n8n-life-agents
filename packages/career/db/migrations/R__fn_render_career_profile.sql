-- ============================================================
-- career.fn_render_career_profile (READ)
--   Render des career_profile-Sidecars, Header-only: autoritativer Fakten-Header (aktuelle Rolle, Branche,
--   Berufsstart, Skills). Die generische Engine core.fn_fetch_context wrappt Banner + Header + _meta-Stempel
--   + Prosa. Ohne diese Render-Zeile wuerde load_context dem LLM nur die rohe Prosa zeigen (die facts
--   blieben unsichtbar).
--   Eingabe: p_name (Name des Sidecars). Uniforme Signatur fn(text)->text.
--   Ableitungen render-at-fetch, nie gespeichert: "Berufsstart vor ~N Jahren" aus career_start_date,
--   "letzter Wechsel vor ~N Jahren" aus last_job_change_date, Skill "seit" roh.
--   Rueckgabe: Header-Text oder NULL (kein facts-Sidecar -> Engine rendert nur Prosa).
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_render_career_profile(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_facts   JSONB;
    v_lines   TEXT[] := '{}';
    v_skills  TEXT[] := '{}';
    v_sk      JSONB;
    v_since   NUMERIC;
    v_start   DATE;
BEGIN
    SELECT c.metadata->'facts' INTO v_facts FROM agent.core_contexts c WHERE c.name = p_name;
    IF v_facts IS NULL OR jsonb_typeof(v_facts) <> 'object' OR v_facts = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    IF v_facts ? 'current_title' THEN
        v_lines := v_lines || ('Aktuelle Rolle: ' || (v_facts->>'current_title')
            || CASE WHEN v_facts ? 'industry' THEN ' (' || (v_facts->>'industry') || ')' ELSE '' END);
    ELSIF v_facts ? 'industry' THEN
        v_lines := v_lines || ('Branche: ' || (v_facts->>'industry'));
    END IF;

    -- Berufsstart roh, die Jahre seitdem render-at-fetch. Bewusst keine Behauptung "N Jahre Berufserfahrung"
    -- (Elternzeit/Teilzeit/Pausen machen sie falsch) — nur, wie lange der Start zurueckliegt.
    v_start := career.fn_partial_date(v_facts->>'career_start_date');
    IF v_start IS NOT NULL THEN
        v_lines := v_lines || ('Berufsstart: ' || (v_facts->>'career_start_date') || ' (vor ~'
            || date_part('year', age(core.fn_today(), v_start))::text || ' Jahren)');
    END IF;

    -- Skills (kompakt, max 8): "Name (level)"
    IF jsonb_typeof(v_facts->'skills') = 'array' THEN
        FOR v_sk IN SELECT * FROM jsonb_array_elements(v_facts->'skills') LIMIT 8 LOOP
            v_skills := v_skills || (COALESCE(v_sk->>'name','?')
                || CASE WHEN v_sk ? 'level' OR career.fn_partial_date(v_sk->>'since') IS NOT NULL
                        THEN ' (' || concat_ws(', ', v_sk->>'level',
                                 CASE WHEN career.fn_partial_date(v_sk->>'since') IS NOT NULL
                                      THEN 'seit ' || (v_sk->>'since') END) || ')'
                        ELSE '' END);
        END LOOP;
        IF array_length(v_skills, 1) > 0 THEN
            v_lines := v_lines || ('Kompetenzen: ' || array_to_string(v_skills, ', '));
        END IF;
    END IF;

    -- Ableitung render-at-fetch: Jahre seit dem letzten Jobwechsel (nie gespeichert)
    -- (Teil-Daten YYYY/YYYY-MM erlaubt; defekt -> Zeile auslassen, kein Crash)
    IF career.fn_partial_date(v_facts->>'last_job_change_date') IS NOT NULL THEN
        v_since := date_part('year', age(core.fn_today(), career.fn_partial_date(v_facts->>'last_job_change_date')));
        v_lines := v_lines || ('Letzter Jobwechsel: vor ~' || v_since::text || ' Jahren ('
            || (v_facts->>'last_job_change_date') || ')');
    END IF;

    IF array_length(v_lines, 1) IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN '- ' || array_to_string(v_lines, E'\n- ');
END;
$$;
