-- ============================================================
-- finance.fn_render_plan_facts (WS1a — paket-gefuetterter Plan-Fakten-RENDER, Header-only)
--   Liefert NUR den autoritativen Fakten-HEADER des 'financial_planning'-Sidecars (Ziel-Kennzahlen,
--   Risikoprofil [Phase A: Bereitschaft/Tragfaehigkeit + Stand], Ziel-Allokation+Korridore, Glidepath).
--   Die generische Core-Engine core.fn_fetch_context wrappt
--   Banner + diesen Header + _meta-Stempel + Prosa-Body (so wie die Validator-Registry die Domaenen-
--   Struktur fuettert, fuettert die Render-Registry core.context_renderers die Domaenen-Darstellung).
--   UNIFORME Signatur fn(text)->text (Context-Name als Argument — die Engine ruft render_fn(name)).
--
--   ABLEITUNGEN rechnet SQL, NIE gespeichert (Root-CLAUDE.md "LLM rechnet nicht"): das Glidepath-START-
--   JAHR aus glidepath.start_age + dem Geburtsdatum der OWNER-Person (Join family, role='owner';
--   Muster finance.fn_render_finance_profile). Fehlt family/owner -> Phase ohne Jahr (defensiv, kein Crash).
--
--   PLAN-LUECKEN (2026-10-27): bei aktivem Plan die englische Zeile "Plan gaps: …" aus finance.fn_plan_gaps
--   (nie bestaetigte Sektionen, fehlende Plan-Zahlen, nur im Draft) — auch bei leerem Sidecar.
--
--   RUECKGABE: Header-Text (mehrzeilig) ODER NULL, wenn die Zeile keinen facts-Sidecar und keine Luecken traegt
--   (dann rendert die Engine nur die Prosa). Anwenden via:
--     db_apply.ps1 -File packages\finance\db\migrations\R__fn_render_plan_facts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_render_plan_facts(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_facts      JSONB;
    v_goal       JSONB;
    v_rp         JSONB;
    v_alloc      JSONB;
    v_gp         JSONB;
    v_er         JSONB;
    v_birth      DATE;
    v_owner_id   TEXT;
    v_ret_age    NUMERIC;
    v_infl       NUMERIC;
    v_income     NUMERIC;
    v_years      NUMERIC;
    v_nominal    NUMERIC;
    v_ret_year   TEXT;
    v_start_age  NUMERIC;
    v_lines      TEXT[] := '{}';
    v_blk        JSONB;
    v_blocks     TEXT[] := '{}';
    v_phases     TEXT[] := '{}';
    v_ph         JSONB;
    v_year       TEXT;
    v_pi         TEXT;
    v_pp         TEXT;
    v_gaps       JSONB;
    v_gap_parts  TEXT[] := '{}';
    v_gap_line   TEXT;
BEGIN
    SELECT c.metadata->'facts' INTO v_facts
    FROM agent.core_contexts c
    WHERE c.name = p_name;

    -- Plan-Luecken (2026-10-27): finance.fn_plan_gaps rechnet, welche Interview-Sektionen nie bestaetigt wurden und
    -- welche Plan-Zahlen fehlen (nur bei aktivem Plan). Englisch = Modell-Instruktions-Schicht; der Berater-Prompt
    -- liest die Zeile ("Plan gaps") und bietet das Schliessen an. Auch bei leerem Sidecar (Import-Plan ohne Fakten).
    v_gaps := finance.fn_plan_gaps(v_facts);
    IF jsonb_array_length(v_gaps->'open_sections') > 0 THEN
        v_gap_parts := v_gap_parts || ('never confirmed in an interview: '
            || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_gaps->'open_sections') x));
    END IF;
    IF jsonb_array_length(v_gaps->'missing_blocks') > 0 THEN
        v_gap_parts := v_gap_parts || ('confirmed but missing plan figure: '
            || (SELECT string_agg((m->>'section') || ' (' || (m->>'block') || ')', ', ')
                FROM jsonb_array_elements(v_gaps->'missing_blocks') m));
    END IF;
    IF jsonb_array_length(v_gaps->'draft_only_sections') > 0 THEN
        v_gap_parts := v_gap_parts || ('saved in the draft, not yet published: '
            || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_gaps->'draft_only_sections') x));
    END IF;
    IF array_length(v_gap_parts, 1) IS NOT NULL THEN
        v_gap_line := 'Plan gaps: ' || array_to_string(v_gap_parts, '; ');
    END IF;

    IF v_facts IS NULL OR jsonb_typeof(v_facts) IS DISTINCT FROM 'object'
       OR v_facts = '{}'::jsonb THEN
        -- kein Fakten-Sidecar -> nur die Luecken-Zeile (falls vorhanden), sonst rendert die Engine nur die Prosa
        RETURN CASE WHEN v_gap_line IS NOT NULL THEN '- ' || v_gap_line END;
    END IF;

    -- Owner-Geburtsdatum + person_id (Single-Writer-Referenz auf family; defensiv: fehlt -> NULL)
    SELECT (pp->>'birth_date')::date, pp->>'person_id' INTO v_birth, v_owner_id
    FROM agent.core_contexts cf,
         jsonb_array_elements(COALESCE(cf.metadata->'facts'->'persons','[]'::jsonb)) pp
    WHERE cf.name = 'family' AND pp->>'role' = 'owner'
    LIMIT 1;

    -- Wunsch-Renteneintrittsalter (= Beginn der Auszahlungsphase, NICHT die gesetzliche Regelaltersgrenze)
    -- des Owners aus finance_profile (Single-Writer-Referenz; fehlt -> NULL). Treibt die Nominal-Projektion
    -- (Jahre bis zum Auszahlungsbeginn) — wird NIE gespeichert, hier render-at-fetch gerechnet.
    IF v_owner_id IS NOT NULL THEN
        SELECT (fp->>'planned_retirement_age')::numeric INTO v_ret_age
        FROM agent.core_contexts c2,
             jsonb_array_elements(COALESCE(c2.metadata->'facts'->'persons','[]'::jsonb)) fp
        WHERE c2.name = 'finance_profile' AND fp->>'person_id' = v_owner_id
        LIMIT 1;
    END IF;

    -- ---------- Ziel ----------
    -- WP2: gespeichert sind zwei von Einkommen/Entnahmerate/Zielportfolio, den dritten leitet fn_plan_goal_resolved ab
    -- (Anzeige "(abgeleitet)"; nie gespeichert).
    v_goal := finance.fn_plan_goal_resolved(v_facts->'goal');
    IF jsonb_typeof(v_goal) = 'object' THEN
        v_lines := v_lines || (
            'Ziel: '
            || CASE WHEN v_goal ? 'target_income_eur_month'
                    THEN (v_goal->>'target_income_eur_month') || ' €/Monat'
                         || CASE WHEN v_goal->>'derived_key' = 'target_income_eur_month' THEN ' (abgeleitet)' ELSE '' END
                    ELSE '—' END
            || CASE WHEN v_goal ? 'target_portfolio_eur'
                    THEN ', Zielportfolio ' ||
                         CASE WHEN jsonb_typeof(v_goal->'target_portfolio_eur') = 'array'
                              THEN (v_goal->'target_portfolio_eur'->>0) || '–' || (v_goal->'target_portfolio_eur'->>1) || ' €'
                              ELSE (v_goal->>'target_portfolio_eur') || ' €' END
                         || CASE WHEN v_goal->>'derived_key' = 'target_portfolio_eur' THEN ' (abgeleitet)' ELSE '' END
                    ELSE '' END
            || CASE WHEN v_goal ? 'horizon_years' THEN ', Horizont ' || (v_goal->>'horizon_years') || ' J' ELSE '' END
            || CASE WHEN v_goal ? 'withdrawal_rate_pct' THEN ', Entnahme ' || (v_goal->>'withdrawal_rate_pct') || ' %'
                         || CASE WHEN v_goal->>'derived_key' = 'withdrawal_rate_pct' THEN ' (abgeleitet)' ELSE '' END
                    ELSE '' END);
            -- Phase A: die fruehere goal-interne ', Risiko <tolerance>'-Klausel ist nach risk_profile umgezogen (s. u.).

        -- real/Inflation-Marker an die Ziel-Zeile (FPA: alle Geld-Ziele REAL, EINE Inflations-Annahme)
        v_infl   := NULLIF(v_goal->>'inflation_pct', '')::numeric;
        v_income := NULLIF(v_goal->>'target_income_eur_month', '')::numeric;
        IF (v_goal ? 'terms') OR v_infl IS NOT NULL THEN
            v_lines[array_length(v_lines, 1)] := v_lines[array_length(v_lines, 1)]
                || ' (' || COALESCE(v_goal->>'terms', 'real')
                || CASE WHEN v_infl IS NOT NULL THEN ', Inflation ' || (v_goal->>'inflation_pct') || ' % p.a.' ELSE '' END
                || ')';
        END IF;
        -- Nominal-Projektion bei Beginn der Auszahlungsphase: real × (1+i)^Jahre; Jahre = Wunsch-Rentenalter − Alter.
        -- ABLEITUNG (nie gespeichert, render-at-fetch): defensiv bei fehlendem Profil/Geburtsdatum -> ausgelassen.
        IF v_income IS NOT NULL AND v_infl IS NOT NULL AND v_birth IS NOT NULL AND v_ret_age IS NOT NULL THEN
            v_years := v_ret_age - date_part('year', age(v_birth));
            IF v_years > 0 THEN
                v_nominal  := round(v_income * power(1 + v_infl / 100, v_years));
                -- floor() statt ::int: planned_retirement_age ist konzeptionell ganzjaehrig; ein direkter
                -- ::int-Cast wuerde 63.5 banker's-runden (->64) und das Jahr still verschieben.
                v_ret_year := to_char(v_birth + make_interval(years => floor(v_ret_age)::int), 'YYYY');
                v_lines := v_lines || (
                    'Kaufkraft: ' || (v_goal->>'target_income_eur_month') || ' €/Monat real ≈ '
                    || v_nominal::text || ' €/Monat nominal bei Beginn der Auszahlungsphase ~' || v_ret_year
                    || ' (' || (v_goal->>'inflation_pct') || ' % Inflation über ' || v_years::text || ' J)');
            END IF;
        END IF;
    END IF;

    -- ---------- Risikoprofil (Phase A: risk_tolerance zog aus goal hierher; + Tragfaehigkeit + Stand) ----------
    -- Eigene Header-Zeile statt der goal-internen Klausel (one-fact-one-home). Partial-tolerant: nur
    -- gesetzte Felder werden gerendert; ohne tolerance UND capacity entfaellt die Zeile ganz.
    v_rp := v_facts->'risk_profile';
    IF jsonb_typeof(v_rp) = 'object'
       AND ((v_rp ? 'risk_tolerance') OR (v_rp ? 'risk_capacity')) THEN
        v_lines := v_lines || (
            'Risiko:'
            || CASE WHEN v_rp ? 'risk_tolerance' THEN ' Bereitschaft ' || (v_rp->>'risk_tolerance') ELSE '' END
            || CASE WHEN (v_rp ? 'risk_tolerance') AND (v_rp ? 'risk_capacity') THEN ',' ELSE '' END
            || CASE WHEN v_rp ? 'risk_capacity' THEN ' Tragfähigkeit ' || (v_rp->>'risk_capacity') ELSE '' END
            || CASE WHEN v_rp ? 'as_of' THEN ' (Stand ' || (v_rp->>'as_of') || ')' ELSE '' END);
    END IF;

    -- ---------- Ziel-Allokation ----------
    v_alloc := v_facts->'target_allocation';
    IF jsonb_typeof(v_alloc) = 'object' AND jsonb_typeof(v_alloc->'blocks') = 'array' THEN
        FOR v_blk IN SELECT * FROM jsonb_array_elements(v_alloc->'blocks') LOOP
            v_blocks := v_blocks || (
                COALESCE(v_blk->>'name','?') || ' ' || COALESCE(v_blk->>'target_pct','?') || '%'
                || CASE WHEN jsonb_typeof(v_blk->'corridor') = 'array'
                        THEN ' (' || (v_blk->'corridor'->>0) || '–' || (v_blk->'corridor'->>1) || ')' ELSE '' END
                -- 2026-10-23: der Block-key ist das Kuerzel, mit dem der Buchhalter Positionen zuordnet (asset_class)
                || CASE WHEN NULLIF(v_blk->>'key', '') IS NOT NULL THEN ' [' || (v_blk->>'key') || ']' ELSE '' END);
        END LOOP;
        v_lines := v_lines || (
            'Ziel-Allokation'
            || CASE WHEN v_alloc ? 'rebalance_drift_pp'
                    THEN ' (Rebalancing-Drift ' || (v_alloc->>'rebalance_drift_pp') || 'pp)' ELSE '' END
            || ': ' || array_to_string(v_blocks, ', '));
    END IF;

    -- ---------- Glidepath (Startjahr = birth_date + start_age, render-at-fetch) ----------
    v_gp := v_facts->'glidepath';
    IF jsonb_typeof(v_gp) = 'object' THEN
        v_start_age := NULLIF(v_gp->>'start_age','')::numeric;
        v_year := CASE WHEN v_birth IS NOT NULL AND v_start_age IS NOT NULL
                       THEN to_char(v_birth + make_interval(years => floor(v_start_age)::int), 'YYYY')
                       ELSE NULL END;
        IF jsonb_typeof(v_gp->'phases') = 'array' THEN
            FOR v_ph IN SELECT * FROM jsonb_array_elements(v_gp->'phases') LOOP
                v_pi := CASE WHEN v_ph ? 'age_from' THEN (v_ph->>'age_from') ELSE NULL END;
                v_pp := CASE WHEN v_ph ? 'age_to' THEN (v_ph->>'age_to') ELSE NULL END;
                v_phases := v_phases || (
                    COALESCE(v_ph->>'name','?')
                    || CASE WHEN v_pi IS NOT NULL OR v_pp IS NOT NULL
                            THEN ' (' || COALESCE(v_pi,'…') || '–' || COALESCE(v_pp,'…') || ')' ELSE '' END
                    || CASE WHEN v_ph ? 'equity_pct' THEN ' ' || (v_ph->>'equity_pct') || '% Aktien' ELSE '' END);
            END LOOP;
        END IF;
        v_lines := v_lines || (
            'Glidepath'
            || CASE WHEN v_gp ? 'start_age'
                    THEN ': De-Risking-Start ' || CASE WHEN v_year IS NOT NULL THEN '~' || v_year || ' ' ELSE '' END
                         || '(Alter ' || (v_gp->>'start_age') || ')' ELSE '' END
            || CASE WHEN array_length(v_phases,1) > 0 THEN ' — Phasen: ' || array_to_string(v_phases, '; ') ELSE '' END);
    END IF;

    -- ---------- Notreserve-Ziel ----------
    v_er := v_facts->'emergency_reserve';
    IF jsonb_typeof(v_er) = 'object' THEN
        IF v_er ? 'target_months' AND jsonb_typeof(v_er->'target_months') = 'number' THEN
            v_lines := v_lines || ('Notreserve-Ziel: ' || (v_er->>'target_months') || ' Monatsausgaben');
        ELSIF v_er ? 'target_eur' AND jsonb_typeof(v_er->'target_eur') = 'number' THEN
            v_lines := v_lines || ('Notreserve-Ziel: ' || (v_er->>'target_eur') || ' €');
        END IF;
    END IF;

    -- ---------- Renten (Renteninformation-Plan 2026-10-26) ----------
    -- Je aktiver Altersvorsorge die juengste Renteninformation aus finance.fn_pension_outlook (EINE Rechen-Adresse),
    -- mit der Plan-Inflation fuer die Kaufkraft der DRV-Szenarien. Der Berater zitiert diese Werte als Spanne.
    FOR v_ph IN SELECT * FROM jsonb_array_elements(
                    finance.fn_pension_outlook(jsonb_build_object('inflation_pct', to_jsonb(v_infl)))->'pensions') LOOP
        v_lines := v_lines || (
            'Rente ' || (v_ph->>'name') || ' (' || COALESCE(v_ph->>'owner', 'Haushalt') || '): '
            || CASE WHEN (v_ph->>'never')::boolean THEN 'noch keine Renteninformation'
                    ELSE 'Stand ' || (v_ph->>'statement_date')
                         || CASE WHEN (v_ph->>'stale')::boolean THEN ' (älter als 13 Monate)' ELSE '' END
                         || CASE WHEN v_ph ? 'reached_claim' THEN ', erreicht ' || (v_ph->>'reached_claim') || ' €' ELSE '' END
                         || CASE WHEN v_ph ? 'projection' THEN ', Hochrechnung ' || (v_ph->>'projection') || ' €' ELSE '' END
                         || CASE WHEN v_ph ? 'scenario_1pct' THEN ', 1 %: ' || (v_ph->>'scenario_1pct') || ' €'
                                 || CASE WHEN v_ph ? 'scenario_1pct_real' THEN ' (Kaufkraft ≈ ' || (v_ph->>'scenario_1pct_real') || ' €)' ELSE '' END
                                 ELSE '' END
                         || CASE WHEN v_ph ? 'scenario_2pct' THEN ', 2 %: ' || (v_ph->>'scenario_2pct') || ' €'
                                 || CASE WHEN v_ph ? 'scenario_2pct_real' THEN ' (Kaufkraft ≈ ' || (v_ph->>'scenario_2pct_real') || ' €)' ELSE '' END
                                 ELSE '' END
                         || CASE WHEN v_ph ? 'em_monthly' THEN ', EM-Rente ' || (v_ph->>'em_monthly') || ' €' ELSE '' END
                         || CASE WHEN v_ph ? 'regular_retirement_date' THEN ', Regelaltersrente ab ' || (v_ph->>'regular_retirement_date') ELSE '' END
                         || '; alles monatlich brutto'
               END);
    END LOOP;

    IF v_gap_line IS NOT NULL THEN
        v_lines := v_lines || v_gap_line;
    END IF;

    IF array_length(v_lines, 1) IS NULL THEN
        RETURN NULL;  -- facts vorhanden, aber leer/ohne bekannte Bloecke -> nur Prosa
    END IF;

    RETURN '- ' || array_to_string(v_lines, E'\n- ');
END;
$$;
