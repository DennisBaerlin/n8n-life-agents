-- ============================================================
-- career.fn_render_career_preferences (WS-2 — Render des career_preferences-Sidecars, Header-only)
--   Liefert den autoritativen Fakten-HEADER der gelernten Job-Praeferenzen (mag/meidet, Gehaltsuntergrenze,
--   Arbeitsort, Pendelweg). Die generische Engine core.fn_fetch_context wrappt Banner/Stempel/Prosa.
--   UNIFORME Signatur fn(text)->text. RUECKGABE: Header-Text ODER NULL (kein facts-Sidecar -> nur Prosa).
--   Vorbild career.fn_render_career_profile. Anwenden via:
--     db_apply.ps1 -File packages\career\db\migrations\R__fn_render_career_preferences.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_render_career_preferences(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_facts JSONB;
    v_lines TEXT[] := '{}';
BEGIN
    SELECT c.metadata->'facts' INTO v_facts FROM agent.core_contexts c WHERE c.name = p_name;
    IF v_facts IS NULL OR jsonb_typeof(v_facts) <> 'object' OR v_facts = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(v_facts->'preferred_aspects') = 'array' AND jsonb_array_length(v_facts->'preferred_aspects') > 0 THEN
        v_lines := v_lines || ('Wichtig: ' || (SELECT string_agg(e, ', ') FROM jsonb_array_elements_text(v_facts->'preferred_aspects') AS e));
    END IF;
    IF jsonb_typeof(v_facts->'disliked_aspects') = 'array' AND jsonb_array_length(v_facts->'disliked_aspects') > 0 THEN
        v_lines := v_lines || ('Vermeiden: ' || (SELECT string_agg(e, ', ') FROM jsonb_array_elements_text(v_facts->'disliked_aspects') AS e));
    END IF;
    IF jsonb_typeof(v_facts->'disliked_industries') = 'array' AND jsonb_array_length(v_facts->'disliked_industries') > 0 THEN
        v_lines := v_lines || ('Branchen meiden: ' || (SELECT string_agg(e, ', ') FROM jsonb_array_elements_text(v_facts->'disliked_industries') AS e));
    END IF;
    IF jsonb_typeof(v_facts->'disliked_employers') = 'array' AND jsonb_array_length(v_facts->'disliked_employers') > 0 THEN
        v_lines := v_lines || ('Arbeitgeber meiden: ' || (SELECT string_agg(e, ', ') FROM jsonb_array_elements_text(v_facts->'disliked_employers') AS e));
    END IF;
    IF v_facts ? 'salary_floor' AND jsonb_typeof(v_facts->'salary_floor') = 'number' THEN
        v_lines := v_lines || ('Gehaltsuntergrenze: ' || (v_facts->>'salary_floor') || ' EUR');
    END IF;
    IF v_facts ? 'remote_preference' AND jsonb_typeof(v_facts->'remote_preference') <> 'null' THEN
        v_lines := v_lines || ('Arbeitsort-Präferenz: ' || (v_facts->>'remote_preference'));
    END IF;
    IF v_facts ? 'commute_max_km' AND jsonb_typeof(v_facts->'commute_max_km') = 'number' THEN
        v_lines := v_lines || ('Max. Pendelweg: ' || (v_facts->>'commute_max_km') || ' km');
    END IF;

    IF array_length(v_lines, 1) IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN '- ' || array_to_string(v_lines, E'\n- ');
END;
$$;
