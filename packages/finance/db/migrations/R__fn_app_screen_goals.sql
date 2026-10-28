-- ============================================================
-- finance.fn_app_screen_goals(p jsonb) — Mini-App-Bildschirm „Ziele" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Muster finance.fn_app_screen_overview.
--   Quellen: savings_goal_progress (Ziele mit Zielbetrag; Ampel = finance.fn_savings_goal_pace, die EINE Regel, die auch
--   der Berater nutzt), maintenance_reserve_status (Ruecklagen), savings_plan_overview (Sparplaene). Die Seite rechnet nichts.
--   Hero = Summe der sichtbaren Ziele mit Zielbetrag (ohne Ruecklagen, = Summe des Abschnitts), gap bei einem Ziel-Anteil
--   ohne Wechselkurs (savings_goal_progress.has_fx_gap).
--   Ruecklage: Pill nur fuer eine aktive Immobilie mit bekannter Luecke zur Empfehlung (NULL meldet nicht falsch, wie
--   der Berater); gap = Stand ohne Wechselkurs (savings_goal_progress.has_fx_gap). Sparplan: der Rhythmus-Text
--   fn_schedule_label ist Modell-Text (englisch) -> nicht angezeigt; Monatsbetrag + naechste Ausfuehrung. Ein
--   angehaltener Plan steht als pausiert da (Soft-Close und gestoppte Beitraege sind in den Daten derselbe Zustand).
--   Bekannt: "hinter Plan" bei einem Ziel mit has_fx_gap ist zu hoch gerechnet -> Item traegt gap, kein Banner (BACKLOG).
--   ZERO-TRUST-SICHTBARKEIT (Rolle loest der Handler selbst auf, core.fn_app_sees_household): owner/partner sehen den
--     Haushalt, alle anderen nur
--     Ziel/Ruecklage mit beneficiary_person_id = ich und Sparplaene mit beneficiary = ich UND eigenem Depot.
--   params.probe = true -> {ok, empty, banners}: Banner "hinter Plan" je sichtbarem Ziel (pace = behind) ohne fx-Luecke
--     (sonst waere der Rueckstand zu hoch gerechnet), target = goals. Der Bildschirm selbst traegt keine Banner (Pills).
--     probe laeuft bei jedem App-Start -> Ruecklagen/Sparplaene nur per EXISTS, nicht als Liste.
--   Fehler als Daten, nie RAISE: Frei-SQL-Sitzung -> forbidden, kaputte Eingabe -> bad_request. Keine IDs in der Antwort.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (EXECUTE nur finance_rw/Host, nie *_ro).
--   Tests: tests/db/finance/test_fn_app_screen_goals.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_goals(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid      text;
    v_hh       boolean;
    v_goals    jsonb;
    v_total    numeric;
    v_gap      boolean;
    v_banners  jsonb;
    v_reserves jsonb;
    v_plans    jsonb;
    v_sections jsonb;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid := p ->> 'person_id';
    v_hh  := core.fn_app_sees_household(v_pid);

    -- Sparziele (aktiv, mit Zielbetrag): Ampel aus fn_savings_goal_pace
    WITH g AS (
        SELECT sg.name, sg.target_amount, sg.target_date, sg.current_amount, sg.progress_percent, sg.priority,
               sg.has_fx_gap, finance.fn_savings_goal_pace(sg.id) AS pace
          FROM finance.savings_goal_progress sg
         WHERE sg.status = 'active' AND sg.target_amount IS NOT NULL
           AND (v_hh OR sg.beneficiary_person_id = v_pid)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', g.name,
               'sub', core.fn_ui_tpl('finance.app.goals.target_by', jsonb_build_object(
                          'target', core.fn_ui_money(g.target_amount, 'EUR'), 'date', core.fn_ui_date(g.target_date))),
               'value', core.fn_ui_money(g.current_amount, 'EUR'),
               'gap', g.has_fx_gap,
               'pill', CASE g.pace
                           WHEN 'on_track' THEN jsonb_build_object('state', 'ok', 'icon', 'check',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.on_track'))
                           WHEN 'behind' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.behind'))
                           WHEN 'reached' THEN jsonb_build_object('state', 'ok', 'icon', 'check',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.reached'))
                           WHEN 'paused' THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))
                           WHEN 'unmeasurable' THEN jsonb_build_object('state', 'neutral', 'icon', 'info',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.unmeasurable'))
                       END,
               'progress', CASE WHEN g.progress_percent IS NOT NULL THEN jsonb_build_object(
                               'pct', round(LEAST(GREATEST(g.progress_percent, 0), 100), 1),
                               'state', CASE g.pace WHEN 'behind' THEN 'warn'
                                                    WHEN 'on_track' THEN 'ok' WHEN 'reached' THEN 'ok'
                                                    ELSE 'neutral' END) END,
               'target', NULL)
             ORDER BY g.target_date, g.priority NULLS LAST, g.name), '[]'::jsonb),
           COALESCE(sum(g.current_amount), 0),
           COALESCE(bool_or(g.has_fx_gap), false),
           COALESCE(jsonb_agg(jsonb_build_object(
               'state', 'warn', 'icon', 'alert',
               'text', core.fn_ui_tpl('finance.app.goals.banner_behind', jsonb_build_object('name', g.name)),
               'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb))
             ORDER BY g.target_date, g.priority NULLS LAST, g.name)
             FILTER (WHERE g.pace = 'behind' AND NOT g.has_fx_gap), '[]'::jsonb)
      INTO v_goals, v_total, v_gap, v_banners
      FROM g;

    -- probe (jeder App-Start): nur Existenz, ohne Ruecklagen-/Sparplan-Listen (next_execution) zu bauen
    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        RETURN jsonb_build_object('ok', true,
            'empty', jsonb_array_length(v_goals) = 0
                     AND NOT EXISTS (SELECT 1 FROM finance.savings_goals g
                                      WHERE g.status = 'active' AND g.real_estate_id IS NOT NULL
                                        AND (v_hh OR g.beneficiary_person_id = v_pid))
                     AND NOT EXISTS (SELECT 1 FROM finance.savings_plans s
                                       JOIN finance.accounts d ON d.id = s.depot_id
                                      WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid)),
            'banners', v_banners);
    END IF;

    -- Ruecklagen (Instandhaltung): Stand, eingestellte Rate, Empfehlung
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', m.goal_name,
               'sub', CASE WHEN m.running_monthly_eur IS NOT NULL AND m.recommended_monthly IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.reserve_rate_rec', jsonb_build_object(
                                    'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR'),
                                    'recommended', core.fn_ui_money(m.recommended_monthly, 'EUR')))
                           WHEN m.running_monthly_eur IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                    'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR'))) END,
               'value', core.fn_ui_money(m.saved_eur, 'EUR'),
               'gap', COALESCE(sg.has_fx_gap, false),
               'pill', CASE WHEN m.property_status <> 'active' THEN NULL
                            WHEN m.gap_monthly_eur > 0
                            THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                     'text', core.fn_ui_tpl('finance.app.goals.reserve_low'))
                            WHEN m.gap_monthly_eur <= 0
                            THEN jsonb_build_object('state', 'ok', 'icon', 'check',
                                     'text', core.fn_ui_tpl('finance.app.goals.reserve_ok')) END,
               'progress', NULL,
               'target', NULL)
             ORDER BY m.goal_name), '[]'::jsonb)
      INTO v_reserves
      FROM finance.maintenance_reserve_status m
      JOIN finance.savings_goals g ON g.id = m.goal_id
      LEFT JOIN finance.savings_goal_progress sg ON sg.id = m.goal_id
     WHERE v_hh OR g.beneficiary_person_id = v_pid;

    -- Sparplaene: aktiv vor pausiert
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', s.name,
               'sub', CASE WHEN s.status = 'active' AND s.next_execution IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.plan_next', jsonb_build_object(
                                    'monthly', core.fn_ui_money(s.monthly_amount, s.currency),
                                    'date', core.fn_ui_date(s.next_execution)))
                           WHEN s.status = 'active'
                           THEN core.fn_ui_tpl('finance.app.goals.plan_monthly', jsonb_build_object(
                                    'monthly', core.fn_ui_money(s.monthly_amount, s.currency))) END,
               'value', core.fn_ui_money(s.amount_per_execution, s.currency),
               'gap', false,
               'pill', CASE WHEN s.status = 'paused'
                            THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                                     'text', core.fn_ui_tpl('finance.app.goals.pace.paused')) END,
               'progress', NULL,
               'target', NULL)
             ORDER BY (s.status = 'active') DESC, s.name), '[]'::jsonb)
      INTO v_plans
      FROM finance.savings_plan_overview s
      JOIN finance.accounts d ON d.id = s.depot_id
     WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid);

    -- Sparziele immer (mit Leer-Text), Ruecklagen/Sparplaene nur mit Eintraegen
    v_sections := jsonb_build_array(jsonb_build_object(
        'title', core.fn_ui_tpl('finance.app.goals.section_goals'),
        'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_goals));
    IF jsonb_array_length(v_reserves) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_reserves'),
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_reserves);
    END IF;
    IF jsonb_array_length(v_plans) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_plans'),
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_plans);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.goals.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.goals.hero'),
            'value', core.fn_ui_money(v_total, 'EUR'),
            'gap', v_gap,
            'note', NULL),
        'banners', '[]'::jsonb,
        'sections', v_sections);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_goals(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
