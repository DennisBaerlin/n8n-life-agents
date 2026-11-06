-- ============================================================
-- estate.fn_gap_report (read-only Gap-Analyse, WS-2 — EINE Quelle fuer Renderer + WS-4-Review)
--   Aggregiert die Vollstaendigkeits-Luecken des Notfall-Registers als jsonb:
--     * directive_gaps: estate.v_directive_gaps (Soll = essential+recommended je ERWACHSENEM;
--       Haushalts-Urkunde deckt beide Partner — Logik lebt in der View, hier nur Aggregation)
--     * register_gaps:  estate.v_register_gaps (offene Feld-/Zeilen-Luecken)
--     * finance:        KONKRETE Feld-Gaps der finance-Register (Plan/Owner-Entscheid 2):
--       je aktiver Versicherung fehlende policy_number/insurance_type + fehlende
--       beneficiary/claim_deadline_hours NUR bei (potenziell) todesfall-relevanten Typen
--       (life|accident|Typ unbekannt — ein Haftpflicht-Bezugsrecht waere Gap-Rauschen);
--       je aktivem Konto offene ownership/has_transmortal_poa.
--   finance-Konsum DOPPEL-GUARDET (core.fn_package_active + to_regprocedure je Call-Site,
--   §4.2 Oberflaeche A) — Absenz = sichtbares finance.status-Feld, NIE stille Auslassung.
--   DRITTER Guard (Pfad-Robustheit): die Oberflaeche-A-fns sind PLAIN INVOKER — unter
--   estate_ro (Frei-SQL des Agenten) wirft der finance-Tabellen-Read insufficient_privilege;
--   der EXCEPTION-Handler degradiert dann auf status 'not_readable_on_this_path' (der volle
--   finance-Blick kommt ueber estate_overview, dessen Renderer im fn_fetch_context-DEFINER
--   laeuft). RAISE-FREI + STABLE; alles schema-qualifiziert (DEFINER-search_path-sicher).
--   RUECKGABE: {ok:true, directive_gaps:[...], register_gaps:[...],
--     finance:{status:'ok'|'absent'|'fns_missing'|'not_readable_on_this_path', gaps:[...]}}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_gap_report.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_gap_report()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_directive JSONB;
    v_register  JSONB;
    v_fin       JSONB := '[]'::jsonb;
    v_fin_state TEXT;
    v_j         JSONB;
    v_e         JSONB;
    v_missing   TEXT[];
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'person_id', g.person_id, 'full_name', g.full_name,
               'doc_type', g.doc_type, 'label', g.label,
               'recommendation', g.recommendation, 'status', g.status)
               ORDER BY g.full_name, g.doc_type), '[]'::jsonb)
      INTO v_directive
      FROM estate.v_directive_gaps g;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'area', g.area, 'ref_id', g.ref_id, 'person_id', g.person_id,
               'item', g.item, 'gap', g.gap, 'gap_code', g.gap_code)
               ORDER BY g.area, g.item), '[]'::jsonb)
      INTO v_register
      FROM estate.v_register_gaps g;

    -- ---------- finance-Feld-Gaps (doppel-guardet + Pfad-Guard) ----------
    -- Der GANZE finance-schema-beruehrende Block liegt in EINEM insufficient_privilege-Handler:
    -- unter estate_ro (Frei-SQL des Agenten) wirft schon das to_regprocedure('finance...') den
    -- Schema-Zugriffsfehler (finance ist D10-gesperrt) — er MUSS mit im Handler liegen, sonst
    -- entkommt er vor der Degradation. Im DEFINER-Renderer (Owner-Rechte) laeuft alles durch.
    IF NOT core.fn_package_active('finance') THEN
        v_fin_state := 'absent';
    ELSE
      BEGIN
        IF to_regprocedure('finance.fn_insurance_register()') IS NULL
           OR to_regprocedure('finance.fn_account_register()') IS NULL THEN
            v_fin_state := 'fns_missing';
        ELSE
            v_fin_state := 'ok';
            EXECUTE 'SELECT finance.fn_insurance_register()' INTO v_j;
            FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) LOOP
                v_missing := '{}';
                IF v_e->>'policy_number' IS NULL THEN v_missing := v_missing || 'policy_number'::text; END IF;
                IF v_e->>'insurance_type' IS NULL THEN v_missing := v_missing || 'insurance_type'::text; END IF;
                -- Bezugsrecht/Meldefrist nur, wo sie im Todesfall tragen (life|accident|Typ unbekannt):
                IF COALESCE(v_e->>'insurance_type', 'unknown') IN ('life', 'accident', 'unknown') THEN
                    IF v_e->>'beneficiary' IS NULL THEN v_missing := v_missing || 'beneficiary'::text; END IF;
                    IF v_e->>'claim_deadline_hours' IS NULL THEN v_missing := v_missing || 'claim_deadline_hours'::text; END IF;
                END IF;
                IF array_length(v_missing, 1) IS NOT NULL THEN
                    v_fin := v_fin || jsonb_build_object(
                        'area', 'insurance', 'item', v_e->>'name', 'missing_fields', to_jsonb(v_missing));
                END IF;
            END LOOP;
            EXECUTE 'SELECT finance.fn_account_register()' INTO v_j;
            FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) LOOP
                v_missing := '{}';
                IF v_e->>'ownership' IS NULL THEN v_missing := v_missing || 'ownership'::text; END IF;
                IF v_e->>'has_transmortal_poa' IS NULL THEN v_missing := v_missing || 'has_transmortal_poa'::text; END IF;
                IF array_length(v_missing, 1) IS NOT NULL THEN
                    v_fin := v_fin || jsonb_build_object(
                        'area', 'account', 'item', v_e->>'name', 'missing_fields', to_jsonb(v_missing));
                END IF;
            END LOOP;
        END IF;
      EXCEPTION WHEN insufficient_privilege THEN
            -- Frei-SQL-Pfad unter estate_ro: schema finance ist D10-gesperrt (schon der
            -- to_regprocedure-Lookup wirft) -> ehrlich degradieren; der volle Blick laeuft
            -- ueber load_context('estate_overview') (DEFINER-Renderer mit Owner-Rechten).
            v_fin_state := 'not_readable_on_this_path';
            v_fin := '[]'::jsonb;
      END;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'directive_gaps', v_directive,
        'register_gaps', v_register,
        'finance', jsonb_build_object('status', v_fin_state, 'gaps', v_fin));
END;
$$;
