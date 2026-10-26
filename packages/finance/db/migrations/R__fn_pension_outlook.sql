-- ============================================================
-- fn_pension_outlook (READ, STABLE) -- Berater-Fenster auf die Renteninformationen (Plan 2026-10-26)
--   Je aktiver Altersvorsorge (finance.pension_overview) die JUENGSTE Renteninformation (finance.pension_statements,
--   Zeitreihe) mit Alter und den gedruckten Werten, dazu die DRV-Szenarien in Kaufkraft zum Stand der Information.
--   Das LLM rechnet nichts davon (Root-CLAUDE.md); der Berater zitiert diese Felder als Spanne.
--     age_months   volle Monate seit statement_date (core.fn_today)
--     stale        juengste Information aelter als 13 Monate (DRV schickt jaehrlich) -- EINE Regel, auch fuer die
--                  Erinnerung (fn_pension_statements_due)
--     never        es gibt noch keine Information
--     years_to_start  Jahre bis Rentenbeginn: pension.retirement_start_date (Plan des Nutzers), sonst die gedruckte
--                  regular_retirement_date
--     scenario_*_real  nominal / (1 + inflation)^n, n = (regular_retirement_date - statement_date) / 365.25 --
--                  der Zeitraum, ueber den die DRV ihre Szenarien hochrechnet (Review 2026-10-26: nicht ab heute,
--                  nicht bis zu einem frueheren Wunsch-Rentenbeginn)
--   p: { person_id (opt, nur diese Person), inflation_pct (opt, Zahl -- die Plan-Annahme; der Aufrufer reicht sie
--        herein, damit finance_ro keine agent.*-Tabelle lesen muss) }
--   RUECKGABE: {ok:true, pensions:[{name, pension_type, provider, owner, owner_person_id, statement_date, age_months,
--   stale, never, regular_retirement_date, years_to_start, earning_points, reached_claim, projection, scenario_1pct,
--   scenario_2pct, em_monthly, scenario_1pct_real, scenario_2pct_real | real_note, basis}]}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_pension_outlook(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_today  DATE    := core.fn_today();
    v_infl   NUMERIC := CASE WHEN jsonb_typeof(p->'inflation_pct') = 'number' THEN (p->>'inflation_pct')::numeric END;
    v_person TEXT    := NULLIF(p->>'person_id', '');
    v_out    JSONB   := '[]'::jsonb;
    v_r      RECORD;
    v_e      JSONB;
    v_n      NUMERIC;
    v_start  DATE;
BEGIN
    FOR v_r IN
        SELECT o.id, o.name, o.pension_type, o.provider, o.owner, o.owner_person_id, o.retirement_start_date, s.*
        FROM finance.pension_overview o
        LEFT JOIN LATERAL (
            SELECT ps.statement_date, ps.reached_claim, ps.projection, ps.scenario_1pct, ps.scenario_2pct, ps.em_monthly,
                   ps.earning_points, ps.regular_retirement_date
            FROM finance.pension_statements ps WHERE ps.pension_id = o.id
            ORDER BY ps.statement_date DESC LIMIT 1) s ON true
        WHERE o.status = 'active' AND (v_person IS NULL OR o.owner_person_id = v_person)
        ORDER BY o.id
    LOOP
        v_start := COALESCE(v_r.retirement_start_date, v_r.regular_retirement_date);
        v_e := jsonb_build_object(
            'name', v_r.name, 'pension_type', v_r.pension_type, 'provider', v_r.provider,
            'owner', v_r.owner, 'owner_person_id', v_r.owner_person_id,
            'never', v_r.statement_date IS NULL);
        IF v_r.statement_date IS NOT NULL THEN
            v_e := v_e || jsonb_strip_nulls(jsonb_build_object(
                'statement_date', v_r.statement_date,
                'age_months', (date_part('year', age(v_today, v_r.statement_date)) * 12
                               + date_part('month', age(v_today, v_r.statement_date)))::int,
                'stale', v_r.statement_date < v_today - interval '13 months',
                'regular_retirement_date', v_r.regular_retirement_date,
                'earning_points', v_r.earning_points, 'reached_claim', v_r.reached_claim, 'projection', v_r.projection,
                'scenario_1pct', v_r.scenario_1pct, 'scenario_2pct', v_r.scenario_2pct, 'em_monthly', v_r.em_monthly,
                'basis', 'Reached claim and projection: pension value at the statement date, without future pension '
                      || 'adjustments (roughly today''s purchasing power if pensions rise with inflation). Scenarios: '
                      || 'nominal at the regular retirement date; *_real = purchasing power at the statement date. All '
                      || 'amounts are gross, before health/care insurance and income tax.'));
            IF v_infl IS NOT NULL AND v_r.regular_retirement_date IS NOT NULL THEN
                v_n := (v_r.regular_retirement_date - v_r.statement_date) / 365.25;
                v_e := v_e || jsonb_strip_nulls(jsonb_build_object(
                    'scenario_1pct_real', round(v_r.scenario_1pct / power(1 + v_infl / 100, v_n), 2),
                    'scenario_2pct_real', round(v_r.scenario_2pct / power(1 + v_infl / 100, v_n), 2),
                    'inflation_pct', v_infl));
            ELSE
                v_e := v_e || jsonb_build_object('real_note', CASE WHEN v_infl IS NULL
                    THEN 'no inflation assumption in the plan - purchasing-power values omitted'
                    ELSE 'no regular retirement date printed - purchasing-power values omitted' END);
            END IF;
        END IF;
        IF v_start IS NOT NULL THEN
            v_e := v_e || jsonb_build_object('years_to_start', round((v_start - v_today) / 365.25, 1));
        END IF;
        v_out := v_out || v_e;
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'pensions', v_out);
END;
$$;
