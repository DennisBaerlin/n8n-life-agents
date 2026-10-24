-- ============================================================
-- career.fn_render_career_profile (WS-1 — Render des career_profile-Sidecars, Header-only)
--   Liefert NUR den autoritativen Fakten-HEADER des 'career_profile'-Sidecars (aktuelle Rolle, Branche,
--   Erfahrung, Skills). Die generische Engine core.fn_fetch_context wrappt Banner + Header + _meta-Stempel
--   + Prosa. Ohne diese Render-Zeile wuerde load_context dem LLM nur die rohe Prosa zeigen (die facts
--   blieben unsichtbar) — der Renderer macht die strukturierten Roh-Fakten zum autoritativen Header.
--   UNIFORME Signatur fn(text)->text. ABLEITUNGEN render-at-fetch, NIE gespeichert (Root-CLAUDE.md "LLM
--   rechnet nicht"): "letzter Wechsel vor ~N Jahren" aus last_job_change_date. RUECKGABE: Header-Text
--   ODER NULL (kein facts-Sidecar -> Engine rendert nur Prosa).
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_render_career_profile.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_render_career_profile(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_facts   JSONB;
    v_lines   TEXT[] := '{}';
    v_skills  TEXT[] := '{}';
    v_sk      JSONB;
    v_since   NUMERIC;
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

    IF v_facts ? 'experience_years' AND jsonb_typeof(v_facts->'experience_years') = 'number' THEN
        v_lines := v_lines || ('Berufserfahrung: ' || (v_facts->>'experience_years') || ' Jahre');
    END IF;

    -- Skills (kompakt, max 8): "Name (level)"
    IF jsonb_typeof(v_facts->'skills') = 'array' THEN
        FOR v_sk IN SELECT * FROM jsonb_array_elements(v_facts->'skills') LIMIT 8 LOOP
            v_skills := v_skills || (COALESCE(v_sk->>'name','?')
                || CASE WHEN v_sk ? 'level' THEN ' (' || (v_sk->>'level') || ')' ELSE '' END);
        END LOOP;
        IF array_length(v_skills, 1) > 0 THEN
            v_lines := v_lines || ('Kompetenzen: ' || array_to_string(v_skills, ', '));
        END IF;
    END IF;

    -- Ableitung render-at-fetch: Jahre seit dem letzten Jobwechsel (nie gespeichert)
    IF v_facts ? 'last_job_change_date' THEN
        BEGIN
            v_since := date_part('year', age((v_facts->>'last_job_change_date')::date));
            v_lines := v_lines || ('Letzter Jobwechsel: vor ~' || v_since::text || ' Jahren ('
                || (v_facts->>'last_job_change_date') || ')');
        EXCEPTION WHEN OTHERS THEN NULL;  -- defekt -> Zeile auslassen, kein Crash
        END;
    END IF;

    IF array_length(v_lines, 1) IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN '- ' || array_to_string(v_lines, E'\n- ');
END;
$$;
