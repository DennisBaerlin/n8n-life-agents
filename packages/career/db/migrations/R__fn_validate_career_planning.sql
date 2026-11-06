-- ============================================================
-- career.fn_validate_career_planning (WS-1 — Validator des career_planning-facts-Sidecars, D12)
--   Strukturvalidierung des advisor-gepflegten 'career_planning'-Sidecars (Ziel-Rollen, Ziel-Branchen,
--   Umstiegs-Timeline). Vorbild finance.fn_validate_financial_planning (partial-tolerant: jeder Top-Block
--   optional). Der Plan-Sidecar wird von core.fn_advisor_publish_plan(domain='career') geschrieben; der
--   Core-Trigger dispatcht die Struktur GENERISCH ueber core.context_validators hierher. Die Derived-Value-
--   Denylist (keine gespeicherten Ableitungen wie computed_months/target_year) liegt im Core-Validator.
--   skill_gaps sind WS-3 (Skill-Gap-Numerik) — die SOLL-Skills je Ziel-Rolle
--   (target_roles[].required_skills[]={name,min_level?,is_blocker?}) werden hier (WS-3) strukturell geprueft
--   (name Pflicht, min_level in der 4-Skala via career.fn_skill_level_rank, kein doppelter Skill-Name je Rolle,
--   is_blocker bool) — der jsonb-Sub-Feld-Backstop. Die Skill-Gap-NUMERIK rechnet career.fn_skill_gap, nie hier.
--   WS-2: die SUCHKRITERIEN des Job-Scanners (target_locations/search_radius_km/employment_types) leben als
--   Block der targets-Sektion in DIESEM Sidecar (Owner-Entscheid: Suchkriterien = career_planning-Fakten,
--   kein Tabellen-Konstrukt) -> der Cron cron.score_jobs liest sie. Hier nur partial-tolerant strukturiert.
--   RUECKGABE: NULL = gueltig, sonst Fehlertext. Anwenden via:
--     db_apply.ps1 -File packages\career\db\migrations\R__fn_validate_career_planning.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_validate_career_planning(p_facts jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_role   JSONB;
    v_sal    NUMERIC;
    v_rad    NUMERIC;
    v_rs     JSONB;
    v_seen   TEXT[];
    v_pm     NUMERIC;
    v_gi     NUMERIC;
BEGIN
    IF p_facts IS NULL OR jsonb_typeof(p_facts) <> 'object' THEN
        RETURN NULL;  -- partial-tolerant: leeres/teilweises Compose erlaubt
    END IF;

    -- target_roles: Array von { title (Pflicht), priority?, salary_expectation_eur?, salary_period?, salary_basis? }
    IF p_facts ? 'target_roles' AND jsonb_typeof(p_facts->'target_roles') <> 'null' THEN
        IF jsonb_typeof(p_facts->'target_roles') <> 'array' THEN
            RETURN 'career_planning.target_roles must be an array';
        END IF;
        FOR v_role IN SELECT * FROM jsonb_array_elements(p_facts->'target_roles') LOOP
            IF length(trim(COALESCE(v_role->>'title', ''))) = 0 THEN
                RETURN 'career_planning.target_roles[].title is required (non-empty)';
            END IF;
            IF v_role ? 'salary_expectation_eur' AND jsonb_typeof(v_role->'salary_expectation_eur') <> 'null' THEN
                IF jsonb_typeof(v_role->'salary_expectation_eur') <> 'number' THEN
                    RETURN 'career_planning.target_roles[].salary_expectation_eur must be a number';
                END IF;
                v_sal := (v_role->>'salary_expectation_eur')::numeric;
                IF v_sal < 0 OR v_sal > 10000000 THEN
                    RETURN format('career_planning.target_roles[].salary_expectation_eur %s out of sane range (0..10000000)', v_sal);
                END IF;
            END IF;
            -- WP3: Gehalt mit Einheit (roh, wie gesagt); den Jahreswert rechnet career.fn_salary_annual beim Anzeigen
            IF v_role ? 'salary_period' AND jsonb_typeof(v_role->'salary_period') <> 'null'
               AND v_role->>'salary_period' NOT IN ('month', 'year') THEN
                RETURN format('career_planning.target_roles[].salary_period "%s" invalid (month|year)', v_role->>'salary_period');
            END IF;
            IF v_role ? 'salary_basis' AND jsonb_typeof(v_role->'salary_basis') <> 'null'
               AND v_role->>'salary_basis' NOT IN ('gross', 'net') THEN
                RETURN format('career_planning.target_roles[].salary_basis "%s" invalid (gross|net)', v_role->>'salary_basis');
            END IF;

            -- WS-3: required_skills[] (Soll-Skills je Ziel-Rolle) — partial-tolerant (fehlt -> ok)
            IF v_role ? 'required_skills' AND jsonb_typeof(v_role->'required_skills') <> 'null' THEN
                IF jsonb_typeof(v_role->'required_skills') <> 'array' THEN
                    RETURN 'career_planning.target_roles[].required_skills must be an array';
                END IF;
                v_seen := '{}';   -- per-Rolle-Dubletten-Check (== der Tabellen-UNIQUE auf Validator-Ebene)
                FOR v_rs IN SELECT * FROM jsonb_array_elements(v_role->'required_skills') LOOP
                    IF length(trim(COALESCE(v_rs->>'name', ''))) = 0 THEN
                        RETURN 'career_planning.target_roles[].required_skills[].name is required (non-empty)';
                    END IF;
                    IF lower(trim(v_rs->>'name')) = ANY(v_seen) THEN
                        RETURN format('career_planning.target_roles[].required_skills[] duplicate skill "%s" within one role', v_rs->>'name');
                    END IF;
                    v_seen := v_seen || lower(trim(v_rs->>'name'));
                    -- min_level gegen die EINE Skala-Quelle (rank=0 <=> ungueltig); fehlt -> presence-only, ok
                    IF v_rs ? 'min_level' AND jsonb_typeof(v_rs->'min_level') <> 'null'
                       AND career.fn_skill_level_rank(v_rs->>'min_level') = 0 THEN
                        RETURN format('career_planning.target_roles[].required_skills[].min_level "%s" invalid (beginner|intermediate|advanced|expert)', v_rs->>'min_level');
                    END IF;
                    IF v_rs ? 'is_blocker' AND jsonb_typeof(v_rs->'is_blocker') NOT IN ('boolean', 'null') THEN
                        RETURN 'career_planning.target_roles[].required_skills[].is_blocker must be a boolean';
                    END IF;
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    -- target_industries: Array (Strings oder { name })
    IF p_facts ? 'target_industries' AND jsonb_typeof(p_facts->'target_industries') <> 'null'
       AND jsonb_typeof(p_facts->'target_industries') <> 'array' THEN
        RETURN 'career_planning.target_industries must be an array';
    END IF;

    -- WP3: Zieldatum ROH (absolut oder relativ wie gesagt, die DB loest "+2 years" beim Speichern auf), nie eine
    -- relative Jahreszahl (timeline_years ist naechstes Jahr falsch; career:V007 hat den Bestand umgerechnet).
    -- KEIN Vergangenheits-Check hier: das Dokument wird bei jedem Publish neu geprueft, ein erreichtes Ziel darf
    -- spaeteres Publizieren nicht blockieren (der Renderer zeigt "ueberschritten").
    IF p_facts ? 'timeline_years' THEN
        RETURN 'career_planning.timeline_years is no longer stored (it is wrong a year later) — pass target_date '
            || 'instead (e.g. 2028 or 2028-06, or relative as stated: +2 years)';
    END IF;
    IF p_facts ? 'target_date' AND jsonb_typeof(p_facts->'target_date') <> 'null'
       AND career.fn_partial_date(p_facts->>'target_date') IS NULL THEN
        RETURN format('career_planning.target_date "%s" must be YYYY, YYYY-MM or YYYY-MM-DD', p_facts->>'target_date');
    END IF;

    -- WS-2 Suchkriterien (targets-Block; Owner-Entscheid Option A):
    -- target_locations: Array von Orten (Strings; -> Cron-Param 'wo')
    IF p_facts ? 'target_locations' AND jsonb_typeof(p_facts->'target_locations') <> 'null'
       AND jsonb_typeof(p_facts->'target_locations') <> 'array' THEN
        RETURN 'career_planning.target_locations must be an array';
    END IF;

    -- search_radius_km: Roh-Zahl 0..500 (-> Cron-Param 'umkreis')
    IF p_facts ? 'search_radius_km' AND jsonb_typeof(p_facts->'search_radius_km') <> 'null' THEN
        IF jsonb_typeof(p_facts->'search_radius_km') <> 'number' THEN
            RETURN 'career_planning.search_radius_km must be a number';
        END IF;
        v_rad := (p_facts->>'search_radius_km')::numeric;
        IF v_rad < 0 OR v_rad > 500 THEN
            RETURN format('career_planning.search_radius_km %s out of range (0..500)', v_rad);
        END IF;
    END IF;

    -- employment_types: Array (z. B. ['vollzeit','teilzeit']; nur tolerant strukturiert)
    IF p_facts ? 'employment_types' AND jsonb_typeof(p_facts->'employment_types') <> 'null'
       AND jsonb_typeof(p_facts->'employment_types') <> 'array' THEN
        RETURN 'career_planning.employment_types must be an array';
    END IF;

    -- WS-5 transition-Block (Runway-Szenario; ROHE Owner-Werte, beide optional): { probation_months?,
    -- expected_gap_income_eur? }. Die ABGELEITETE Runway (runway_months/covers/effective_burn) rechnet
    -- career.fn_runway render-at-fetch und wird NIE gespeichert — die Core-Denylist (agent.fn_validate_
    -- household_facts) sperrt diese Keys generisch (DB-Backstop).
    IF p_facts ? 'transition' AND jsonb_typeof(p_facts->'transition') <> 'null' THEN
        IF jsonb_typeof(p_facts->'transition') <> 'object' THEN
            RETURN 'career_planning.transition must be an object';
        END IF;
        IF (p_facts->'transition') ? 'probation_months'
           AND jsonb_typeof(p_facts->'transition'->'probation_months') <> 'null' THEN
            IF jsonb_typeof(p_facts->'transition'->'probation_months') <> 'number' THEN
                RETURN 'career_planning.transition.probation_months must be a number';
            END IF;
            v_pm := (p_facts->'transition'->>'probation_months')::numeric;
            IF v_pm < 0 OR v_pm > 24 THEN
                RETURN format('career_planning.transition.probation_months %s out of range (0..24)', v_pm);
            END IF;
        END IF;
        IF (p_facts->'transition') ? 'expected_gap_income_eur'
           AND jsonb_typeof(p_facts->'transition'->'expected_gap_income_eur') <> 'null' THEN
            IF jsonb_typeof(p_facts->'transition'->'expected_gap_income_eur') <> 'number' THEN
                RETURN 'career_planning.transition.expected_gap_income_eur must be a number';
            END IF;
            v_gi := (p_facts->'transition'->>'expected_gap_income_eur')::numeric;
            IF v_gi < 0 OR v_gi > 1000000 THEN
                RETURN format('career_planning.transition.expected_gap_income_eur %s out of range (0..1000000)', v_gi);
            END IF;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;
