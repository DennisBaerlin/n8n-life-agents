-- ============================================================
-- career.fn_validate_career_preferences (WS-2 — Validator des career_preferences-facts-Sidecars, D12)
--   Strukturvalidierung des 2. paket-besessenen Fakten-Kontexts (gelernte Job-Praeferenzen aus dem
--   👍/👎-Feedback-Loop: was der Owner mag/meidet). Vorbild career.fn_validate_career_profile; der Sidecar
--   wird vom Advisor via tool_set_career_preferences (= 2. Bindung von agent.fn_set_context_facts,
--   context_name='career_preferences', owner_only) geschrieben. Der Core-Trigger trg_core_contexts_validate_
--   facts_fn dispatcht GENERISCH ueber core.context_validators hierher. Fehlt die Registry-Zeile (Paket nicht
--   installiert), entfaellt der career-Anteil still.
--   PARTIAL-TOLERANT: jedes Feld optional (Praeferenzen wachsen aus dem Feedback). Der Scorer re-injiziert
--   diesen Kontext beim naechsten Lauf -> Lernschleife. RUECKGABE: NULL = gueltig, sonst Fehlertext.
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_validate_career_preferences.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_validate_career_preferences(p_facts jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_arr_keys CONSTANT text[] := ARRAY['preferred_aspects', 'disliked_aspects', 'disliked_industries', 'disliked_employers'];
    v_k  TEXT;
    v_rp TEXT;
BEGIN
    IF p_facts IS NULL OR jsonb_typeof(p_facts) <> 'object' THEN
        RETURN NULL;  -- partial-tolerant: Praeferenzen entstehen schrittweise
    END IF;

    -- Stichwort-Arrays (Freitext): jeweils ein Array, falls vorhanden
    FOREACH v_k IN ARRAY v_arr_keys LOOP
        IF p_facts ? v_k AND jsonb_typeof(p_facts->v_k) <> 'null'
           AND jsonb_typeof(p_facts->v_k) <> 'array' THEN
            RETURN format('career_preferences.%s must be an array', v_k);
        END IF;
    END LOOP;

    -- salary_floor: Roh-Zahl 0..10000000 (Untergrenze, die der Owner akzeptiert)
    IF p_facts ? 'salary_floor' AND jsonb_typeof(p_facts->'salary_floor') <> 'null' THEN
        IF jsonb_typeof(p_facts->'salary_floor') <> 'number' THEN
            RETURN 'career_preferences.salary_floor must be a number';
        END IF;
        IF (p_facts->>'salary_floor')::numeric < 0 OR (p_facts->>'salary_floor')::numeric > 10000000 THEN
            RETURN format('career_preferences.salary_floor %s out of sane range (0..10000000)', p_facts->>'salary_floor');
        END IF;
    END IF;

    -- commute_max_km: Roh-Zahl 0..2000
    IF p_facts ? 'commute_max_km' AND jsonb_typeof(p_facts->'commute_max_km') <> 'null' THEN
        IF jsonb_typeof(p_facts->'commute_max_km') <> 'number' THEN
            RETURN 'career_preferences.commute_max_km must be a number';
        END IF;
        IF (p_facts->>'commute_max_km')::numeric < 0 OR (p_facts->>'commute_max_km')::numeric > 2000 THEN
            RETURN format('career_preferences.commute_max_km %s out of range (0..2000)', p_facts->>'commute_max_km');
        END IF;
    END IF;

    -- remote_preference: ENUM remote|hybrid|onsite|any
    IF p_facts ? 'remote_preference' AND jsonb_typeof(p_facts->'remote_preference') <> 'null' THEN
        v_rp := lower(p_facts->>'remote_preference');
        IF v_rp NOT IN ('remote', 'hybrid', 'onsite', 'any') THEN
            RETURN format('career_preferences.remote_preference "%s" invalid (remote|hybrid|onsite|any)', p_facts->>'remote_preference');
        END IF;
    END IF;

    RETURN NULL;
END;
$$;
