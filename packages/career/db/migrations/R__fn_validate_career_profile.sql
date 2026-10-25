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
    v_key    TEXT;
    v_d      DATE;
BEGIN
    IF p_facts IS NULL OR jsonb_typeof(p_facts) <> 'object' THEN
        RETURN NULL;  -- facts optional (Profil entsteht schrittweise)
    END IF;

    -- WP3: Berufserfahrung als STARTDATUM (roh, Genauigkeit der Angabe), nie als Jahreszahl ("12 Jahre" ist naechstes
    -- Jahr falsch). experience_years ist darum abgeloest (career:V007 hat den Bestand umgerechnet).
    IF p_facts ? 'experience_years' THEN
        RETURN 'career_profile.experience_years is no longer stored (it is wrong a year later) — pass career_start_date '
            || 'instead: the year or date the person started working (e.g. 2014), or relative as stated (e.g. -12 years)';
    END IF;
    FOREACH v_key IN ARRAY ARRAY['career_start_date', 'last_job_change_date'] LOOP
        IF p_facts ? v_key AND jsonb_typeof(p_facts->v_key) <> 'null' THEN
            v_d := career.fn_partial_date(p_facts->>v_key);
            IF v_d IS NULL THEN
                RETURN format('career_profile.%s "%s" must be YYYY, YYYY-MM or YYYY-MM-DD', v_key, p_facts->>v_key);
            END IF;
            IF v_d > core.fn_today() THEN
                RETURN format('career_profile.%s %s is in the future', v_key, p_facts->>v_key);
            END IF;
        END IF;
    END LOOP;

    -- skills: Array von { name (Pflicht), level? (beginner|intermediate|advanced|expert), since? }
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
            -- WP3: seit wann (roh), nicht wie viele Jahre (abgeleitet, jaehrlich falsch)
            IF v_sk ? 'years_experience' THEN
                RETURN 'career_profile.skills[].years_experience is no longer stored — pass since instead (year or date, e.g. 2019, or -5 years)';
            END IF;
            IF v_sk ? 'since' AND jsonb_typeof(v_sk->'since') <> 'null' THEN
                v_d := career.fn_partial_date(v_sk->>'since');
                IF v_d IS NULL OR v_d > core.fn_today() THEN
                    RETURN format('career_profile.skills[].since "%s" must be a past YYYY, YYYY-MM or YYYY-MM-DD', v_sk->>'since');
                END IF;
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
