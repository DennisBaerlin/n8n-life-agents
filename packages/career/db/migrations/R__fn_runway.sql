-- ============================================================
-- career.fn_runway (READ)
--   Runway-Bruecke, Consumer-Seite ("kann ich mir den Jobwechsel leisten?"): rechnet deterministisch in der DB,
--   wie viele Monate die cash-only Liquiditaet die Ausgaben deckt, wenn waehrend der Probezeit das Gehalt
--   wegfaellt, vs die Probezeit-Laenge. Liest die provider-eigene finance.fn_liquidity_snapshot() (cash/burn) +
--   die rohen Szenario-Fakten aus dem career_planning-Plan.
--   Eingabe: p_plan_facts, optional transition.probation_months (Default 6, §622 Abs.3 BGB) und
--   transition.expected_gap_income_eur (Default 0 = Worst Case "wenn alles wegfaellt"); falsch getypte Werte
--   fallen auf den Default. Wie career.fn_market_trend / career.fn_skill_gap: DB rechnet, Render liest.
--
--   Cross-Paket-optional (docs/package-contract.md "Cross-package reads"): career nimmt nicht an, dass das
--   finance-Paket installiert ist. Doppel-Guard vor dem Read: core.fn_package_active('finance') [Lifecycle-
--   Praesenz] und to_regprocedure('finance.fn_liquidity_snapshot()') [Objekt-Praesenz, deckt Build-Skew] ->
--   bei jedem Miss RETURN NULL (Runway-Zeile entfaellt graceful, kein RAISE). career.requires bleibt [].
--   Ebenfalls NULL, wenn der Snapshot has_data nicht true meldet.
--
--   Schema-qualifiziert durchgehend (finance.*/core.* explizit): der Render-Pfad laeuft via core.fn_fetch_context
--   (DEFINER, search_path pg_catalog,agent,core ohne finance/career; der Renderer laeuft als dessen Owner =
--   Superuser und liest finance.* trotz context_ro-Binding ohne neuen Grant). Kein eigenes SECURITY DEFINER
--   (Auditierbarkeits-Ersatz fuer den fehlenden Grant-Trail = dieser Kommentar + die Manifest-consumes.reads-
--   Deklaration + der Render-unter-Pin-Test test_fn_render_career_planning). Muster: career.fn_market_trend.
--
--   RAISE-frei: kein Cast auf Junk (jsonb_typeof-Guards), Division durch 0 geguarded (effective_burn<=0 ->
--   runway_months NULL = Notfall-Einkommen deckt die Ausgaben, unbegrenzt + covers=true).
--   Rueckgabe jsonb|NULL:
--     { cash_eur, monthly_expenses_eur, gap_income, effective_burn, runway_months, probation_months, covers,
--       has_fx_gap }
--   has_fx_gap = ein Fremdwaehrungs-Cash-Konto ohne FX-Kurs fehlt in cash_eur (Runway dann zu optimistisch).
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
    -- Doppel-Guard: finance-Paket optional. Beide vor dem Read; bei Miss graceful NULL.
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
    -- Ein Fremdwaehrungs-Cash-Konto ohne FX-Kurs faellt still aus cash_eur -> Runway zu optimistisch.
    -- Flag durchreichen (der Renderer haengt einen Warnhinweis an), nie still unterzaehlen.
    v_fxgap := COALESCE((v_snap->>'has_fx_gap')::boolean, false);

    -- rohe Szenario-Fakten (vom Nutzer genannt). Defaults: Probezeit 6 Mon. (§622 Abs.3 BGB),
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
