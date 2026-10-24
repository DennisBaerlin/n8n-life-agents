-- ============================================================
-- career.fn_market_trend (WS-4 — deterministischer Stellen-Nachfrage-Trend der primaeren Ziel-Rolle)
--   Rechnet fuer target_roles[0] den Posting-Count-Trend (aktuellste Messung + Delta gegen die vorherige
--   Messung desselben scope) DETERMINISTISCH in der DB (CLAUDE.md "LLM rechnet nicht"). Karriere-Analog von
--   career.fn_skill_gap (DB rechnet, Render liest), liest den datierten Cache career.market_signals (vom
--   Cron befuellt) — NICHT die kuratierten Fakten (arch-challenge D1). Genutzt vom Renderer
--   (fn_render_career_planning) -> Markt-Zeile im Plan.
--
--   SCHEMA-QUALIFIZIERT durchgehend (career.*/agent.* explizit): der Render-Pfad laeuft via
--   core.fn_fetch_context (DEFINER, search_path pg_catalog,agent,core OHNE career; der Renderer laeuft als
--   dessen Owner = Superuser -> liest career.* trotz context_ro-Binding). KEINE SECURITY DEFINER noetig
--   (plain wie fn_skill_gap); der Render-unter-context_ro-Test (test_fn_render_career_planning) deckt die
--   Rollen-Perspektiv-Pflicht.
--
--   RAISE-FREI: kein Cast auf Junk, Division durch 0 geguarded, fehlende Rolle/Zahlen/Cache-Zeilen -> NULL.
--   RUECKGABE jsonb (oder NULL, wenn keine Daten):
--     { role, location, count, prev_count, trend_pct, direction, as_of }
--     trend_pct/direction nur bei >= 2 Messungen (sonst trend_pct null, direction 'flat').
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_market_trend.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_market_trend(p_plan_facts jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_role   jsonb;
    v_title  text;
    v_loc    text;
    v_key    text;
    v_cnt    int;
    v_prev   int;
    v_as_of  date;
    v_trend  numeric;
    v_dir    text;
BEGIN
    IF p_plan_facts IS NULL OR jsonb_typeof(p_plan_facts) <> 'object'
       OR jsonb_typeof(p_plan_facts->'target_roles') <> 'array'
       OR jsonb_array_length(p_plan_facts->'target_roles') = 0 THEN
        RETURN NULL;
    END IF;

    v_role  := p_plan_facts->'target_roles'->0;
    v_title := NULLIF(trim(COALESCE(v_role->>'title', '')), '');
    v_loc   := NULLIF(trim(COALESCE(p_plan_facts->'target_locations'->>0, '')), '');
    IF v_title IS NULL THEN
        RETURN NULL;
    END IF;

    v_key := career.fn_market_scope_key('postings', v_title, COALESCE(v_loc, ''));

    -- juengste Messung
    SELECT ms.postings_count, ms.as_of INTO v_cnt, v_as_of
      FROM career.market_signals ms
     WHERE ms.scope_key = v_key AND ms.postings_count IS NOT NULL
     ORDER BY ms.as_of DESC LIMIT 1;
    IF v_cnt IS NULL THEN
        RETURN NULL;
    END IF;

    -- vorherige Messung (zweitjuengste) -> Trend
    SELECT ms.postings_count INTO v_prev
      FROM career.market_signals ms
     WHERE ms.scope_key = v_key AND ms.postings_count IS NOT NULL AND ms.as_of < v_as_of
     ORDER BY ms.as_of DESC LIMIT 1;
    IF v_prev IS NOT NULL AND v_prev > 0 THEN
        v_trend := round((v_cnt - v_prev)::numeric / v_prev * 100, 1);
        v_dir   := CASE WHEN v_cnt > v_prev THEN 'up'
                        WHEN v_cnt < v_prev THEN 'down' ELSE 'flat' END;
    ELSE
        v_dir := 'flat';   -- nur EINE Messung -> kein Trend
    END IF;

    RETURN jsonb_build_object(
        'role',       v_title,
        'location',   v_loc,
        'count',      v_cnt,
        'prev_count', v_prev,
        'trend_pct',  v_trend,
        'direction',  v_dir,
        'as_of',      v_as_of);
END $$;
