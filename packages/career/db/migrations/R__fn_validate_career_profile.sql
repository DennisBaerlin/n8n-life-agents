-- ============================================================
-- career.fn_validate_career_profile (WS-1 — Validator des career_profile-facts-Sidecars, D12)
--   Strukturvalidierung des paket-besessenen 'career_profile'-Sidecars (aktuelle Rolle/Branche/
--   Erfahrung/Skills). Vorbild finance.fn_validate_finance_profile, aber OWNER-SCOPED (v1 = der
--   Owner-Lebenslauf, KEINE persons[]-/family-Kopplung wie finance_profile). Die generische Derived-
--   Value-Denylist (gespeicherte Ableitungen verbieten) liegt im Core-Validator agent.fn_validate_
--   household_facts und laeuft im Trigger fuer JEDEN Sidecar — hier nur die career-Strukturregeln.
--   Der Core-Trigger trg_core_contexts_validate_facts_fn dispatcht GENERISCH ueber core.context_validators
--   hierher (NEW.name='career_profile' -> validate_fn -> dyn. EXECUTE). Fehlt die Registry-Zeile (Paket
--   nicht installiert), entfaellt der career-Anteil still (graceful degradation).
--   PARTIAL-TOLERANT: jedes Feld optional; geprueft wird nur, was vorhanden ist (Profil waechst
--   konversationell). RUECKGABE: NULL = gueltig, sonst Fehlertext (der Trigger uebersetzt ihn in RAISE;
--   der freundliche {ok:false}-Pfad liegt im HITL-Tool/fn_set_context_facts).
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_validate_career_profile.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_validate_career_profile(p_facts jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sk     JSONB;
    v_yrs    NUMERIC;
BEGIN
    IF p_facts IS NULL OR jsonb_typeof(p_facts) <> 'object' THEN
        RETURN NULL;  -- facts optional (Profil entsteht schrittweise)
    END IF;

    -- experience_years: Roh-Zahl 0..80 (kein abgeleitetes Alter — die Denylist sperrt 'age' separat)
    IF p_facts ? 'experience_years' AND jsonb_typeof(p_facts->'experience_years') <> 'null' THEN
        IF jsonb_typeof(p_facts->'experience_years') <> 'number' THEN
            RETURN 'career_profile.experience_years must be a number';
        END IF;
        v_yrs := (p_facts->>'experience_years')::numeric;
        IF v_yrs < 0 OR v_yrs > 80 THEN
            RETURN format('career_profile.experience_years %s out of range (0..80)', v_yrs);
        END IF;
    END IF;

    -- skills: Array von { name (Pflicht), level? (beginner|intermediate|advanced|expert), years_experience? }
    IF p_facts ? 'skills' AND jsonb_typeof(p_facts->'skills') <> 'null' THEN
        IF jsonb_typeof(p_facts->'skills') <> 'array' THEN
            RETURN 'career_profile.skills must be an array';
        END IF;
        FOR v_sk IN SELECT * FROM jsonb_array_elements(p_facts->'skills') LOOP
            IF length(trim(COALESCE(v_sk->>'name', ''))) = 0 THEN
                RETURN 'career_profile.skills[].name is required (non-empty)';
            END IF;
            -- Skill-Level gegen die EINE Skala-Quelle pruefen (rank=0 <=> ungueltig; WS-3 single-source-of-truth)
            IF v_sk ? 'level' AND jsonb_typeof(v_sk->'level') <> 'null'
               AND career.fn_skill_level_rank(v_sk->>'level') = 0 THEN
                RETURN format('career_profile.skills[].level "%s" invalid (beginner|intermediate|advanced|expert)', v_sk->>'level');
            END IF;
            IF v_sk ? 'years_experience' AND jsonb_typeof(v_sk->'years_experience') = 'number'
               AND (v_sk->>'years_experience')::numeric < 0 THEN
                RETURN 'career_profile.skills[].years_experience must be >= 0';
            END IF;
        END LOOP;
    END IF;

    -- as_of: gueltiges Datum, nicht in der Zukunft (sonst defeated den Staleness-Monitor)
    IF p_facts ? 'as_of' AND jsonb_typeof(p_facts->'as_of') <> 'null' THEN
        BEGIN
            IF (p_facts->>'as_of')::date > CURRENT_DATE THEN
                RETURN format('career_profile.as_of %s is in the future', p_facts->>'as_of');
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RETURN format('career_profile.as_of "%s" is not a valid DATE (YYYY-MM-DD)', p_facts->>'as_of');
        END;
    END IF;

    RETURN NULL;
END;
$$;
