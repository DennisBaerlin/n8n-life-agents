-- ============================================================
-- finance.fn_app_screen_goals(p jsonb) — Mini-App-Bildschirm „Ziele" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Muster finance.fn_app_screen_overview.
--   Quellen: savings_goal_progress (Ziele mit Zielbetrag; Ampel = finance.fn_savings_goal_pace, die EINE Regel, die auch
--   der Berater nutzt), savings_goal_account_share (wo liegt das Geld), account_reserve_status + depot_reserve_status
--   (fuer Ziele verplant je Konto/Depot), maintenance_reserve_status (Ruecklagen + Herleitung nach II. BV),
--   savings_plan_overview (Sparplaene), recurring_cashflow_classified (Spar-Abbuchungen je Konto, dieselbe Klassifikation
--   wie der Berater). Die Seite rechnet nichts.
--   Hero = Summe der sichtbaren Ziele mit Zielbetrag (ohne Ruecklagen, = Summe des Abschnitts), gap bei einem Ziel-Anteil
--   ohne Wechselkurs (savings_goal_progress.has_fx_gap).
--   Abschnitte (Uebersicht R3, Owner 2026-10-28):
--   1 Sparziele: Untertitel „Ziel x bis Datum · noch 16 J. 5 Mon." (Restzeit aus age(); nicht bei erreicht/ueberfaellig;
--     Abkuerzungen, weil der Katalog keine Plural-Formen kennt). Aufklappen: Sparrate des heute gueltigen Glieds +
--     Abbuchungskonto, dann je Konto der Anteil (savings_goal_account_share; Summe = Zielstand).
--   2 Fuer Ziele verplant: Konten (account_reserve_status) und Depots (depot_reserve_status) mit Reserve; Balken =
--     verplanter Anteil, „von Stand · frei Rest", Pille gedeckt / nicht gedeckt / nicht ermittelbar. Unbekannt (Depot
--     ohne Kurs, Ziel-Anteil ohne Wechselkurs) ist nie gruen. Keine Zielnamen. Die Deckungsluecke ist KEIN Banner: der
--     Berater unterdrueckt sie, wenn das Ziel im Plan ist (fn_advisor_review), ein zweiter Alarm wuerde davon abweichen.
--   3 Ruecklagen: Pill nur fuer eine aktive Immobilie mit bekannter Luecke zur Empfehlung (NULL meldet nicht falsch, wie
--     der Berater); gap = Stand ohne Wechselkurs. Aufklappen: Herleitung (Immobilie, Wohnflaeche, Baujahr/Alter, Satz je
--     m2 und Jahr, Jahres- = Monatsbetrag, eingestellte Rate) bzw. „Wohnflaeche oder Baujahr fehlt".
--   4 Sparplaene: Wert = Monatsbetrag, Untertitel „Betrag je Ausfuehrung · naechste Datum" (fn_schedule_label ist
--     Modell-Text und wird nicht angezeigt), Summe der aktiven Plaene im Abschnittstitel. Ein angehaltener Plan steht als
--     pausiert da; die Titel-Summe entfaellt, wenn ein aktiver Plan keinen Wechselkurs hat (sonst still zu niedrig).
--     Aufklappen: Wertpapier, Depot, Abbuchungskonto + Beguenstigter (nur Haushalt), Sparziel, geplante
--     Aenderung, Position heute (depot_holdings_overview, Depot + ISIN/Symbol).
--   5 Spar-Abbuchungen je Konto: Summe der laufenden Spar-Abfluesse (cashflow_class saving/saving_internal) je
--     Abbuchungskonto in Kontowaehrung, aufklappbar je Rate. Bewusst ohne Gesamtzeile (interne Umbuchungen zaehlten doppelt).
--   Bekannt: "hinter Plan" bei einem Ziel mit has_fx_gap ist zu hoch gerechnet -> Item traegt gap, kein Banner (BACKLOG).
--   ZERO-TRUST-SICHTBARKEIT (Rolle loest der Handler selbst auf, core.fn_app_sees_household): owner/partner sehen den
--     Haushalt, alle anderen nur Ziel/Ruecklage mit beneficiary_person_id = ich, Sparplaene mit beneficiary = ich UND
--     eigenem Depot, Konten/Depots/Abbuchungen mit owner_person_id = ich. Ein fremdes Konto in den Ziel-Details heisst
--     fuer sie neutral „Haushaltskonto".
--   params.probe = true -> {ok, empty, banners}: Banner "hinter Plan" je sichtbarem Ziel (pace = behind) ohne fx-Luecke
--     (sonst waere der Rueckstand zu hoch gerechnet), target = goals. Der Bildschirm selbst traegt keine Banner (Pills).
--     probe laeuft bei jedem App-Start -> nur Ziele + Ampel, Ruecklagen/Sparplaene/Spar-Abbuchungen/verplantes Geld
--     per EXISTS, keine Details.
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
    v_pid       text;
    v_hh        boolean;
    v_goals     jsonb;
    v_total     numeric;
    v_gap       boolean;
    v_banners   jsonb;
    v_planned   jsonb;
    v_reserves  jsonb;
    v_plans     jsonb;
    v_plans_sum numeric;
    v_outflows  jsonb;
    v_sections  jsonb;
    v_hh_acct   jsonb := core.fn_ui_tpl('finance.app.common.household_account');
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid := p ->> 'person_id';
    v_hh  := core.fn_app_sees_household(v_pid);

    -- probe (jeder App-Start): Ziele + Ampel fuer Banner, Ruecklagen/Sparplaene nur per EXISTS, keine Details
    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        WITH g AS (
            SELECT sg.name, sg.target_date, sg.priority, sg.has_fx_gap, finance.fn_savings_goal_pace(sg.id) AS pace
              FROM finance.savings_goal_progress sg
             WHERE sg.status = 'active' AND sg.target_amount IS NOT NULL
               AND (v_hh OR sg.beneficiary_person_id = v_pid)
        )
        SELECT jsonb_build_object('ok', true,
                   'empty', count(*) = 0
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_goals sg
                                             WHERE sg.status = 'active' AND sg.real_estate_id IS NOT NULL
                                               AND (v_hh OR sg.beneficiary_person_id = v_pid))
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_plans s
                                              JOIN finance.accounts d ON d.id = s.depot_id
                                             WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid))
                            -- Spar-Abbuchungen ohne Ziel/Plan (z. B. nur ein Vorsorge-Beitrag) halten den Bildschirm sichtbar
                            AND NOT EXISTS (SELECT 1 FROM finance.recurring_cashflow_classified c
                                             WHERE c.cashflow_class IN ('saving', 'saving_internal') AND c.monthly_equivalent < 0
                                               AND (v_hh OR c.account_owner_person_id = v_pid))
                            -- verplantes Geld eines Ziels ohne Zielbetrag haelt ihn ebenso sichtbar
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_goal_account_share s
                                              JOIN finance.accounts a ON a.id = s.account_id
                                             WHERE s.goal_status = 'active' AND (v_hh OR a.owner_person_id = v_pid)),
                   'banners', COALESCE(jsonb_agg(jsonb_build_object(
                       'state', 'warn', 'icon', 'alert',
                       'text', core.fn_ui_tpl('finance.app.goals.banner_behind', jsonb_build_object('name', g.name)),
                       'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb))
                     ORDER BY g.target_date, g.priority NULLS LAST, g.name)
                     FILTER (WHERE g.pace = 'behind' AND NOT g.has_fx_gap), '[]'::jsonb))
          INTO v_banners
          FROM g;
        RETURN v_banners;
    END IF;

    -- 1 Sparziele (aktiv, mit Zielbetrag): Ampel aus fn_savings_goal_pace, Restzeit, Details (Rate, Konten-Anteile)
    WITH g AS (
        SELECT sg.id, sg.name, sg.target_amount, sg.target_date, sg.current_amount, sg.progress_percent, sg.priority,
               sg.has_fx_gap, sg.recurring_payment_id, finance.fn_savings_goal_pace(sg.id) AS pace,
               age(sg.target_date, current_date) AS left_age
          FROM finance.savings_goal_progress sg
         WHERE sg.status = 'active' AND sg.target_amount IS NOT NULL
           AND (v_hh OR sg.beneficiary_person_id = v_pid)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', g.name,
               'sub', CASE WHEN g.pace IS DISTINCT FROM 'reached' AND g.target_date > current_date
                           THEN core.fn_ui_tpl('finance.app.goals.target_by_left', jsonb_build_object(
                                    'target', core.fn_ui_money(g.target_amount, 'EUR'), 'date', core.fn_ui_date(g.target_date),
                                    'left', CASE
                                        WHEN extract(year FROM g.left_age) > 0 AND extract(month FROM g.left_age) > 0
                                        THEN core.fn_ui_tpl('finance.app.goals.left_ym', jsonb_build_object(
                                                 'years', core.fn_ui_num(extract(year FROM g.left_age)),
                                                 'months', core.fn_ui_num(extract(month FROM g.left_age))))
                                        WHEN extract(year FROM g.left_age) > 0
                                        THEN core.fn_ui_tpl('finance.app.goals.left_y', jsonb_build_object(
                                                 'years', core.fn_ui_num(extract(year FROM g.left_age))))
                                        WHEN extract(month FROM g.left_age) > 0
                                        THEN core.fn_ui_tpl('finance.app.goals.left_m', jsonb_build_object(
                                                 'months', core.fn_ui_num(extract(month FROM g.left_age))))
                                        ELSE core.fn_ui_tpl('finance.app.goals.left_lt_month') END))
                           ELSE core.fn_ui_tpl('finance.app.goals.target_by', jsonb_build_object(
                                    'target', core.fn_ui_money(g.target_amount, 'EUR'), 'date', core.fn_ui_date(g.target_date)))
                      END,
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
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o, x.k), '[]'::jsonb) FROM (
                   -- Sparrate des heute gueltigen Glieds (laufend), Abbuchungskonto nur wenn sichtbar
                   SELECT 1 AS o, ''::text AS k, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_rate'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object(
                                  'rate', core.fn_ui_money(abs(rp.monthly_equivalent), ra.currency),
                                  'account', CASE WHEN v_hh OR ra.owner_person_id = v_pid THEN to_jsonb(ra.name)
                                                  ELSE v_hh_acct END))) AS d
                     FROM finance.recurring_payments rp
                     JOIN finance.accounts ra ON ra.id = rp.account_id
                    -- „laeuft gerade" = exakt das Praedikat von finance.active_recurring_payments
                    WHERE rp.id = finance.fn_recurring_current(g.recurring_payment_id, current_date)
                      AND rp.status = 'active' AND rp.valid_from <= current_date
                      AND (rp.valid_to IS NULL OR rp.valid_to > current_date)
                   UNION ALL
                   -- wo liegt das Geld: je Konto der Anteil (Summe = Zielstand)
                   SELECT 2, s.account_name, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object(
                                  'account', CASE WHEN v_hh OR sa.owner_person_id = v_pid THEN to_jsonb(s.account_name)
                                                  ELSE v_hh_acct END)),
                              'value', CASE WHEN s.share_native IS NOT NULL THEN core.fn_ui_money(s.share_native, s.account_currency)
                                            ELSE core.fn_ui_money(s.share_eur, 'EUR') END)
                     FROM finance.savings_goal_account_share s
                     JOIN finance.accounts sa ON sa.id = s.account_id
                    WHERE s.goal_id = g.id AND COALESCE(s.share_native, s.share_eur, 0) <> 0) x))
             ORDER BY g.target_date, g.priority NULLS LAST, g.name), '[]'::jsonb),
           COALESCE(sum(g.current_amount), 0),
           COALESCE(bool_or(g.has_fx_gap), false)
      INTO v_goals, v_total, v_gap
      FROM g;

    -- 2 Fuer Ziele verplant: Konten (Saldo-basiert) und Depots (Marktwert-basiert), unbekannt nie gruen
    WITH c AS (
        SELECT r.account_name AS name, r.currency, r.reserved, r.balance AS base, r.breach, false AS unknown
          FROM finance.account_reserve_status r
          JOIN finance.accounts a ON a.id = r.account_id
         WHERE r.reserved > 0 AND (v_hh OR a.owner_person_id = v_pid)
        UNION ALL
        SELECT r.account_name, 'EUR', r.reserved, r.market_value, r.breach,
               r.fx_missing OR sg.share_gap
               OR EXISTS (SELECT 1 FROM finance.depot_holdings_overview o
                           WHERE o.account_id = r.account_id AND o.market_value_eur IS NULL)
          FROM finance.depot_reserve_status r
          JOIN finance.accounts a ON a.id = r.account_id
          CROSS JOIN LATERAL (
              SELECT EXISTS (SELECT 1 FROM finance.savings_goal_account_share s
                              WHERE s.account_id = r.account_id AND s.goal_status = 'active' AND s.has_fx_gap) AS share_gap
          ) sg
         WHERE (r.reserved > 0 OR sg.share_gap) AND (v_hh OR a.owner_person_id = v_pid)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', c.name,
               'sub', CASE WHEN c.base IS NOT NULL AND NOT c.unknown
                           THEN core.fn_ui_tpl('finance.app.goals.planned_of', jsonb_build_object(
                                    'base', core.fn_ui_money(c.base, c.currency),
                                    'free', core.fn_ui_money(c.base - c.reserved, c.currency))) END,
               'value', core.fn_ui_money(c.reserved, c.currency),
               'gap', c.unknown,
               'pill', CASE WHEN c.unknown
                            THEN jsonb_build_object('state', 'neutral', 'icon', 'info',
                                     'text', core.fn_ui_tpl('finance.app.goals.cover_unknown'))
                            WHEN c.breach
                            THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                     'text', core.fn_ui_tpl('finance.app.goals.cover_short'))
                            ELSE jsonb_build_object('state', 'ok', 'icon', 'check',
                                     'text', core.fn_ui_tpl('finance.app.goals.cover_ok')) END,
               'progress', CASE WHEN NOT c.unknown AND c.reserved > 0 THEN jsonb_build_object(
                               'pct', CASE WHEN c.base > 0 THEN round(LEAST(100 * c.reserved / c.base, 100), 1) ELSE 100 END,
                               'state', CASE WHEN c.breach THEN 'warn' ELSE 'neutral' END) END,
               'target', NULL)
             ORDER BY c.name), '[]'::jsonb)
      INTO v_planned
      FROM c;

    -- 3 Ruecklagen (Instandhaltung): Stand, eingestellte Rate, Empfehlung + Herleitung zum Aufklappen
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
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) FROM (
                   SELECT 1 AS o, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_property'),
                              'value', m.real_estate_name) AS d
                   UNION ALL
                   SELECT 2, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_area'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_area_value', jsonb_build_object(
                                  'area', core.fn_ui_num(m.living_area_m2, scale(trim_scale(m.living_area_m2))))))
                    WHERE m.living_area_m2 IS NOT NULL
                   UNION ALL
                   SELECT 3, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_built'),
                              'value', CASE WHEN m.age_years IS NOT NULL
                                            THEN core.fn_ui_tpl('finance.app.goals.d_built_value', jsonb_build_object(
                                                     'year', m.year_built::text, 'age', core.fn_ui_num(m.age_years)))
                                            ELSE to_jsonb(m.year_built::text) END)
                    WHERE m.year_built IS NOT NULL
                   UNION ALL
                   SELECT 4, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate_m2'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_rate_m2_value', jsonb_build_object(
                                  'rate', core.fn_ui_money(m.rate_eur_m2, 'EUR'))))
                    WHERE m.rate_eur_m2 IS NOT NULL
                   UNION ALL
                   SELECT 5, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_recommended'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_recommended_value', jsonb_build_object(
                                  'annual', core.fn_ui_money(m.recommended_annual, 'EUR'),
                                  'monthly', core.fn_ui_money(m.recommended_monthly, 'EUR'))))
                    WHERE m.recommended_monthly IS NOT NULL
                   UNION ALL
                   SELECT 6, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_missing'), 'value', NULL)
                    WHERE m.recommended_monthly IS NULL AND (m.living_area_m2 IS NULL OR m.year_built IS NULL)
                   UNION ALL
                   SELECT 7, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_running'),
                              'value', core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                  'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR'))))
                    WHERE m.running_monthly_eur IS NOT NULL) x))
             ORDER BY m.goal_name), '[]'::jsonb)
      INTO v_reserves
      FROM finance.maintenance_reserve_status m
      JOIN finance.savings_goals g ON g.id = m.goal_id
      LEFT JOIN finance.savings_goal_progress sg ON sg.id = m.goal_id
     WHERE v_hh OR g.beneficiary_person_id = v_pid;

    -- 4 Sparplaene: aktiv vor pausiert, Wert = Monatsbetrag, Details
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', s.name,
               'sub', CASE WHEN s.status = 'active' AND s.next_execution IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.plan_exec_next', jsonb_build_object(
                                    'amount', core.fn_ui_money(s.amount_per_execution, s.currency),
                                    'date', core.fn_ui_date(s.next_execution)))
                           WHEN s.status = 'active'
                           THEN core.fn_ui_tpl('finance.app.goals.plan_exec', jsonb_build_object(
                                    'amount', core.fn_ui_money(s.amount_per_execution, s.currency))) END,
               'value', core.fn_ui_money(s.monthly_amount, s.currency),
               'gap', false,
               'pill', CASE WHEN s.status = 'paused'
                            THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                                     'text', core.fn_ui_tpl('finance.app.goals.pace.paused')) END,
               'progress', NULL,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) FROM (
                   SELECT 1 AS o, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_security'),
                              'value', CASE WHEN s.isin IS NOT NULL
                                            THEN core.fn_ui_tpl('finance.app.goals.d_security_value', jsonb_build_object(
                                                     'name', COALESCE(s.security_name, s.symbol), 'isin', s.isin))
                                            ELSE to_jsonb(COALESCE(s.security_name, s.symbol)) END) AS d
                    WHERE COALESCE(s.security_name, s.symbol) IS NOT NULL
                   UNION ALL
                   SELECT 2, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_depot'), 'value', s.depot_name)
                   UNION ALL
                   SELECT 3, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_from'),
                              'value', s.settlement_account_name)
                    WHERE v_hh
                   UNION ALL
                   SELECT 4, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_for'), 'value', bp.full_name)
                    WHERE v_hh AND bp.full_name IS NOT NULL
                   UNION ALL
                   SELECT 5, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_goal'),
                              'value', s.savings_goal_name)
                    WHERE s.savings_goal_name IS NOT NULL
                   UNION ALL
                   SELECT 6, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_change', jsonb_build_object(
                                           'date', core.fn_ui_date(s.change_from))),
                              'value', core.fn_ui_tpl('finance.app.goals.plan_exec', jsonb_build_object(
                                           'amount', core.fn_ui_money(s.new_amount_per_execution, s.currency))))
                    WHERE s.change_from IS NOT NULL AND s.new_amount_per_execution IS NOT NULL
                   UNION ALL
                   SELECT 7, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_position'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_position_value', jsonb_build_object(
                                  'value', CASE WHEN o.market_value_eur IS NOT NULL
                                                THEN core.fn_ui_money(o.market_value_eur, 'EUR') END,
                                  'book', core.fn_ui_money(o.book_value, o.currency))))
                     FROM (SELECT ho.market_value_eur, ho.book_value, ho.currency
                             FROM finance.depot_holdings_overview ho
                            WHERE ho.account_id = s.depot_id
                              AND ((s.isin IS NOT NULL AND ho.isin = s.isin) OR ho.symbol = s.symbol)
                            ORDER BY (ho.isin IS NOT DISTINCT FROM s.isin) DESC, ho.holding_id
                            LIMIT 1) o) x))
             ORDER BY (s.status = 'active') DESC, s.name), '[]'::jsonb),
           -- Summe nur ohne fehlenden Wechselkurs (sonst still zu niedrig): NULL -> entfaellt
           CASE WHEN NOT COALESCE(bool_or(finance.fn_to_eur(s.monthly_amount, s.currency) IS NULL)
                                  FILTER (WHERE s.status = 'active'), false)
                THEN sum(finance.fn_to_eur(s.monthly_amount, s.currency)) FILTER (WHERE s.status = 'active') END
      INTO v_plans, v_plans_sum
      FROM finance.savings_plan_overview s
      JOIN finance.accounts d ON d.id = s.depot_id
      LEFT JOIN core.fn_household_persons() bp ON bp.person_id = s.beneficiary_person_id
     WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid);

    -- 5 Spar-Abbuchungen je Konto (laufende Spar-Abfluesse, Klassifikation wie der Berater), aufklappbar je Rate
    WITH r AS (
        SELECT c.account_id, c.account_name, c.currency, c.name, -c.monthly_equivalent AS monthly
          FROM finance.recurring_cashflow_classified c
         WHERE c.cashflow_class IN ('saving', 'saving_internal') AND c.monthly_equivalent < 0
           AND (v_hh OR c.account_owner_person_id = v_pid)
    ), a AS (
        SELECT r.account_name, r.currency, sum(r.monthly) AS monthly,
               jsonb_agg(jsonb_build_object('label', r.name,
                   'value', core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                'rate', core.fn_ui_money(r.monthly, r.currency))))
                 ORDER BY r.monthly DESC, r.name) AS details
          FROM r
         GROUP BY r.account_id, r.account_name, r.currency
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', a.account_name,
               'sub', NULL,
               'value', core.fn_ui_money(a.monthly, a.currency),
               'gap', false,
               'pill', NULL,
               'progress', NULL,
               'target', NULL,
               'details', a.details)
             ORDER BY finance.fn_to_eur(a.monthly, a.currency) DESC NULLS LAST, a.account_name), '[]'::jsonb)
      INTO v_outflows
      FROM a;

    -- Sparziele immer (mit Leer-Text), alles Weitere nur mit Eintraegen
    v_sections := jsonb_build_array(jsonb_build_object(
        'title', core.fn_ui_tpl('finance.app.goals.section_goals'),
        'value', NULL,
        'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_goals));
    IF jsonb_array_length(v_planned) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_planned'),
            'value', NULL,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_planned);
    END IF;
    IF jsonb_array_length(v_reserves) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_reserves'),
            'value', NULL,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_reserves);
    END IF;
    IF jsonb_array_length(v_plans) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_plans'),
            'value', CASE WHEN v_plans_sum > 0 THEN core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                                        'rate', core.fn_ui_money(v_plans_sum, 'EUR'))) END,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_plans);
    END IF;
    IF jsonb_array_length(v_outflows) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_outflows'),
            'value', NULL,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_outflows);
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
