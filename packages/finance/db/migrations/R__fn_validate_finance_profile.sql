-- ============================================================
-- finance.fn_validate_finance_profile (WS-B1 / D12 — Validator-Stub-Split)
--   Strukturvalidierung des paket-besessenen 'finance_profile'-Sidecars (Steuerklasse/
--   Vorsorgesystem/geplantes Renteneintrittsalter + Single-Writer-Referenz auf family).
--   Ausgelagert aus dem Core-Validator agent.fn_validate_household_facts: Core kennt die
--   finance_profile-Strukturregeln nicht mehr; der Core-Trigger trg_core_contexts_validate_facts_fn
--   dispatcht GENERISCH ueber die Registry core.context_validators hierher (WS-B1: NEW.name ->
--   validate_fn -> dyn. EXECUTE, kein hartkodierter finance-Name im Core) -> fehlt die Registry-Zeile
--   (Paket nicht installiert/deinstalliert), validiert Core 'family' weiter und die finance_profile-
--   Strukturregeln entfallen still (graceful degradation).
--
--   Form + Referenz der persons[] (Array von Objekten, eindeutiges person_id, jede person_id existiert in
--   family) prueft seit Phase A GENERISCH der Core-Validator agent.fn_validate_household_facts (reservierte
--   Core-Form-Keys) -> hier NICHT wiederholt, ebenso die Derived-Value-Denylist. Diese fn prueft nur die
--   finance-eigenen Felder.
--
--   RUECKGABE: NULL = gueltig; sonst eine englische Fehlermeldung (Layer 1), die der Core-Trigger
--   in eine RAISE EXCEPTION uebersetzt (Backstop; der freundliche {ok:false}-Pfad liegt im HITL-Tool).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_validate_finance_profile(p_facts jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_p          JSONB;
    v_id         TEXT;
    v_int        INT;
BEGIN
    IF p_facts IS NULL OR jsonb_typeof(p_facts->'persons') IS DISTINCT FROM 'array' THEN RETURN NULL; END IF;  -- Form: Core
    FOR v_p IN SELECT * FROM jsonb_array_elements(p_facts->'persons') LOOP
        v_id := v_p->>'person_id';
        IF v_p ? 'planned_retirement_age' AND jsonb_typeof(v_p->'planned_retirement_age') <> 'null' THEN
            BEGIN v_int := (v_p->>'planned_retirement_age')::int;
            EXCEPTION WHEN OTHERS THEN RETURN format('person "%s": planned_retirement_age must be an integer', v_id); END;
            IF v_int < 40 OR v_int > 80 THEN
                RETURN format('person "%s": planned_retirement_age %s out of range 40..80', v_id, v_int);
            END IF;
        END IF;
        IF v_p ? 'steuerklasse' AND jsonb_typeof(v_p->'steuerklasse') <> 'null' THEN
            BEGIN v_int := (v_p->>'steuerklasse')::int;
            EXCEPTION WHEN OTHERS THEN RETURN format('person "%s": steuerklasse must be an integer', v_id); END;
            IF v_int < 1 OR v_int > 6 THEN
                RETURN format('person "%s": steuerklasse %s out of range 1..6', v_id, v_int);
            END IF;
        END IF;
        IF v_p ? 'vorsorgesystem' AND jsonb_typeof(v_p->'vorsorgesystem') <> 'null'
           AND v_p->>'vorsorgesystem' NOT IN ('grv','versorgungswerk','beamtenversorgung','none') THEN
            RETURN format('person "%s": vorsorgesystem must be grv|versorgungswerk|beamtenversorgung|none', v_id);
        END IF;
        IF v_p ? 'as_of' AND jsonb_typeof(v_p->'as_of') <> 'null' THEN
            BEGIN PERFORM (v_p->>'as_of')::date;
            EXCEPTION WHEN OTHERS THEN RETURN format('person "%s": as_of is not a valid DATE', v_id); END;
            IF (v_p->>'as_of')::date > CURRENT_DATE THEN
                RETURN format('person "%s": as_of %s is in the future (would silently defeat the freshness monitor)', v_id, v_p->>'as_of');
            END IF;
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
