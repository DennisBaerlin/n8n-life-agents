-- ============================================================
-- career.fn_runway (WS-5 — Runway-Bruecke, Consumer-Seite: "kann ich mir den Jobwechsel leisten?")
--   Rechnet DETERMINISTISCH in der DB (CLAUDE.md "LLM rechnet nicht") die Runway: wie viele Monate die
--   cash-only Liquiditaet die Ausgaben deckt, wenn waehrend der Probezeit das Gehalt wegfaellt — vs die
--   Probezeit-Laenge. Liest die provider-eigene finance.fn_liquidity_snapshot() (cash/burn) + die ROHEN
--   Szenario-Fakten aus dem career_planning-Plan (transition.probation_months / .expected_gap_income_eur).
--   Karriere-Analog von career.fn_market_trend (WS-4) / career.fn_skill_gap (WS-3): DB rechnet, Render liest.
--
--   CROSS-PAKET-OPTIONAL (docs/package-contract.md "Cross-package reads"): career nimmt NICHT an, dass das
--   finance-Paket installiert ist. DOPPEL-GUARD vor dem Read: core.fn_package_active('finance') [Lifecycle-
--   Praesenz] UND to_regprocedure('finance.fn_liquidity_snapshot()') [Objekt-Praesenz, deckt Build-Skew] ->
--   bei JEDEM Miss RETURN NULL (Runway-Zeile entfaellt graceful, kein RAISE). career.requires bleibt [].
--
--   SCHEMA-QUALIFIZIERT durchgehend (finance.*/core.* explizit): der Render-Pfad laeuft via core.fn_fetch_context
--   (DEFINER, search_path pg_catalog,agent,core OHNE finance/career; der Renderer laeuft als dessen Owner =
--   Superuser -> liest finance.* trotz context_ro-Binding OHNE neuen Grant). KEIN eigenes SECURITY DEFINER
--   (Auditierbarkeits-Ersatz fuer den fehlenden Grant-Trail = dieser Kommentar + die Manifest-consumes.reads-
--   Deklaration + der Render-unter-Pin-Test test_fn_render_career_planning). Muster: career.fn_market_trend.
--
--   RAISE-FREI: kein Cast auf Junk (jsonb_typeof-Guards), Division durch 0 geguarded (effective_burn<=0 ->
--   runway_months NULL = Notfall-Einkommen deckt die Ausgaben, unbegrenzt + covers=true). RUECKGABE jsonb|NULL:
--     { cash_eur, monthly_expenses_eur, gap_income, effective_burn, runway_months, probation_months, covers }
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_runway.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_runway(p_plan_facts jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tr       jsonb;
    v_snap     jsonb;
    v_cash     numeric;
    v_exp      numeric;
    v_gap      numeric;
    v_prob     int;
    v_effburn  numeric;
    v_runway   int;
    v_covers   boolean;
    v_fxgap    boolean;
BEGIN
    -- Doppel-Guard: finance-Paket optional. BEIDE vor dem Read; bei Miss graceful NULL.
    IF NOT core.fn_package_active('finance')
       OR to_regprocedure('finance.fn_liquidity_snapshot()') IS NULL THEN
        RETURN NULL;
    END IF;

    v_snap := finance.fn_liquidity_snapshot();
    IF v_snap IS NULL OR (v_snap->>'has_data')::boolean IS DISTINCT FROM true THEN
        RETURN NULL;   -- keine finanziellen Daten -> keine sinnvolle Runway
    END IF;

    v_cash := COALESCE((v_snap->>'cash_eur')::numeric, 0);
    v_exp  := COALESCE((v_snap->>'monthly_expenses_eur')::numeric, 0);
    -- WP-3c: ein Fremdwaehrungs-Cash-Konto ohne FX-Kurs faellt still aus cash_eur -> Runway zu optimistisch.
    -- Flag durchreichen (der Renderer haengt einen Warnhinweis an), nie still unterzaehlen.
    v_fxgap := COALESCE((v_snap->>'has_fx_gap')::boolean, false);

    -- rohe Szenario-Fakten (Owner-genannt). Defaults: Probezeit 6 Mon. (§622 Abs.3 BGB),
    -- Notfall-Einkommen 0 (Worst Case "wenn alles wegfaellt"). jsonb_typeof-Guard -> RAISE-frei.
    v_tr   := CASE WHEN jsonb_typeof(p_plan_facts->'transition') = 'object' THEN p_plan_facts->'transition' ELSE '{}'::jsonb END;
    v_prob := CASE WHEN jsonb_typeof(v_tr->'probation_months') = 'number'
                   THEN floor((v_tr->>'probation_months')::numeric)::int ELSE 6 END;
    v_gap  := CASE WHEN jsonb_typeof(v_tr->'expected_gap_income_eur') = 'number'
                   THEN (v_tr->>'expected_gap_income_eur')::numeric ELSE 0 END;

    v_effburn := v_exp - v_gap;
    IF v_effburn > 0 THEN
        v_runway := floor(v_cash / v_effburn)::int;
        v_covers := v_runway >= v_prob;
    ELSE
        v_runway := NULL;        -- Notfall-Einkommen deckt die Ausgaben -> unbegrenzt
        v_covers := true;
    END IF;

    RETURN jsonb_build_object(
        'cash_eur',             round(v_cash, 2),
        'monthly_expenses_eur', round(v_exp, 2),
        'gap_income',           round(v_gap, 2),
        'effective_burn',       round(v_effburn, 2),
        'runway_months',        v_runway,
        'probation_months',     v_prob,
        'covers',               v_covers,
        'has_fx_gap',           v_fxgap);
END $$;
