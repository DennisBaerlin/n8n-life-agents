-- ============================================================
-- finance.fn_app_screen_loans(p jsonb) — Mini-App-Bildschirm „Kredite“ (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Vertrag wie finance.fn_app_screen_overview.
--   Quelle finance.loan_overview, nur ausstehende Kredite (finance.fn_loan_is_outstanding = active + paused). Je Kredit:
--   Rohname, Restschuld positiv in Kontowaehrung, Untertitel „Zins · Rate · schuldenfrei {Jahr}" bzw. „· Schlussrate
--   {Datum}" (Tilgung erst nach dem Laufzeitende fertig), gap wie loan_summary (Restschuld ohne Kurs), Balken „getilgt“
--   nur mit Kreditbetrag (Prozent rechnet die DB).
--   HERO = Restschuld gesamt in EUR; Note „Raten im Monat · davon Zins" (EUR-Summen der aktiven Kredite). Haushalts-
--     Betrachter: Kredite eines Kindes (Kreditnehmer role = 'child') zaehlen nicht (Uebersicht R3, wie die Vermoegen-
--     Seite) und stehen im Abschnitt „Kinder · nicht in der Summe". Die Vermoegen-Zeile „Kredite" (networth_by_asset_class,
--     Kreditkonto-Besitzer = Kreditnehmer) ist dieselbe Zahl, solange das Kreditkonto eines ausstehenden Kredits aktiv
--     ist (Randfall: dort zaehlt das Kreditkonto, hier der Kreditstatus).
--   Pille nur als Urteil (Mini-App UX 2026-10-30, Prioritaet warn vor neutral): Zinsbindung endet in [heute, heute +
--   finance.fixed_rate_warn_months) -> warn + Banner (mit voraussichtlicher Restschuld zum Bindungsende, wenn
--   loan_overview sie kennt), auch wenn pausiert; Bindung schon abgelaufen -> warn ohne Banner (das Datum ist evtl. nur
--   nicht nachgepflegt); pausiert -> neutral. „schuldenfrei {Jahr}" (loan_overview.payoff_date_projected; nicht, wenn
--   die Tilgung erst nach dem Laufzeitende fertig waere) ist ein Fakt und steht im Untertitel; das Jahr ist Klartext
--   (fn_ui_num setzte Tausenderpunkte).
--   Aufklappen (details, NULL-Zeilen entfallen): Bank, Kreditnehmer (nur Haushalt), Kreditbetrag + Auszahlung, getilgt,
--   Zins/Tilgung der Rate, Zinsbindung + Restschuld dann, Laufzeitende + Restschuld dann, schuldenfrei voraussichtlich,
--   Zinsen bis dahin.
--   Der Kreditgeber (lender) ist fuer Haushalts-Betrachter keine schutzwuerdige Information (Owner 2026-10-28; ein Kind
--   sieht ohnehin nur eigene Kredite); er steht seit 2026-10-30 im Aufklappen (Untertitel einzeilig). Keine Kontonamen,
--   keine IDs.
--   ZERO-TRUST-SICHTBARKEIT (core.fn_app_sees_household): owner/partner sehen alle; sonst nur borrower_person_id = ich
--   (Haushaltskredit mit NULL bleibt unsichtbar).
--   params.probe = true -> {ok, empty, banners} (eigene schlanke Abfrage: ohne Details und Tilgungs-Simulation).
--   Summen (Raten-Note, Kinder-Summe) entfallen bei fehlendem Wechselkurs, statt still zu niedrig zu sein.
--   Fehler als Daten, nie RAISE (forbidden / bad_request).
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (Muster overview).
--   Tests: tests/db/finance/test_fn_app_screen_loans.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_loans(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid      text;
    v_hh       boolean;
    v_today    date := CURRENT_DATE;
    v_warn_to  date;
    v_items    jsonb;
    v_kids     jsonb;
    v_kid_sum  numeric;
    v_banners  jsonb;
    v_total    numeric;
    v_gap      boolean;
    v_rate     numeric;
    v_interest numeric;
    v_sections jsonb;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid     := p ->> 'person_id';
    v_hh      := core.fn_app_sees_household(v_pid);
    v_warn_to := (v_today + make_interval(months =>
                    COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'fixed_rate_warn_months'), '')::int, 12)))::date;

    -- probe (jeder App-Start): nur Existenz + Bindungs-Banner, ohne Details und ohne Tilgungs-Simulation
    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        SELECT jsonb_build_object('ok', true, 'empty', count(*) = 0,
                   'banners', COALESCE(jsonb_agg(jsonb_build_object(
                       'state', 'warn', 'icon', 'calendar',
                       'text', CASE WHEN lo.balance_at_fixed_until_projected IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.loans.banner_fixed_ends_rest', jsonb_build_object(
                                    'name', lo.name, 'date', core.fn_ui_date(lo.interest_rate_fixed_until),
                                    'rest', core.fn_ui_money(abs(lo.balance_at_fixed_until_projected), lo.currency)))
                           ELSE core.fn_ui_tpl('finance.app.loans.banner_fixed_ends', jsonb_build_object(
                                    'name', lo.name, 'date', core.fn_ui_date(lo.interest_rate_fixed_until))) END,
                       'target', jsonb_build_object('screen', 'loans', 'params', '{}'::jsonb))
                     ORDER BY lo.interest_rate_fixed_until, lo.name)
                     FILTER (WHERE lo.interest_rate_fixed_until >= v_today AND lo.interest_rate_fixed_until < v_warn_to),
                     '[]'::jsonb))
          INTO v_banners
          FROM finance.loan_overview lo
         WHERE finance.fn_loan_is_outstanding(lo.status)
           AND (v_hh OR lo.borrower_person_id = v_pid);
        RETURN v_banners;
    END IF;

    WITH l AS (
        SELECT lo.*,
               (v_hh AND hp.role IS NOT DISTINCT FROM 'child') AS kid,
               hp.full_name AS borrower_name,
               -- warn vor neutral: auch ein pausierter Kredit braucht die Anschlussfinanzierung
               CASE WHEN lo.interest_rate_fixed_until >= v_today AND lo.interest_rate_fixed_until < v_warn_to THEN 'ends'
                    WHEN lo.interest_rate_fixed_until < v_today THEN 'ended'
                    WHEN lo.status = 'paused' THEN 'paused' END AS flag,
               (lo.payoff_date_projected IS NOT NULL
                AND (lo.term_end_date IS NULL OR lo.payoff_date_projected <= lo.term_end_date)) AS payoff_ok,
               -- Schlussrate: zum Laufzeitende bleibt eine Restschuld (Tilgung erst danach fertig)
               (lo.term_end_date IS NOT NULL AND lo.balance_at_term_end_projected IS NOT NULL
                AND abs(lo.balance_at_term_end_projected) > 0
                AND (lo.payoff_date_projected IS NULL OR lo.payoff_date_projected > lo.term_end_date)) AS final_rate
          FROM finance.loan_overview lo
          LEFT JOIN core.fn_household_persons() hp ON hp.person_id = lo.borrower_person_id
         WHERE finance.fn_loan_is_outstanding(lo.status)
           AND (v_hh OR lo.borrower_person_id = v_pid)
    ), it AS (
        SELECT l.*, jsonb_build_object(
               'label', l.name,
               -- Untertitel „Zins · Rate · schuldenfrei {Jahr}" bzw. „· Schlussrate {Datum}" (Fakten, keine Pille; Mini-App
               -- UX 2026-10-30), die Bank steht im Aufklappen
               'sub', CASE WHEN l.payoff_ok
                           THEN core.fn_ui_tpl('finance.app.loans.rate_line_payoff', jsonb_build_object(
                                    'interest', core.fn_ui_num(l.interest_rate, 2),
                                    'rate', core.fn_ui_money(l.monthly_annuity, l.currency),
                                    'year', to_char(l.payoff_date_projected, 'YYYY')))
                           WHEN l.final_rate
                           THEN core.fn_ui_tpl('finance.app.loans.rate_line_final', jsonb_build_object(
                                    'interest', core.fn_ui_num(l.interest_rate, 2),
                                    'rate', core.fn_ui_money(l.monthly_annuity, l.currency),
                                    'date', core.fn_ui_date(l.term_end_date)))
                           ELSE core.fn_ui_tpl('finance.app.loans.rate_line', jsonb_build_object(
                                    'interest', core.fn_ui_num(l.interest_rate, 2),
                                    'rate', core.fn_ui_money(l.monthly_annuity, l.currency))) END,
               'value', core.fn_ui_money(abs(l.current_remaining_debt), l.currency),
               'gap', COALESCE(l.current_remaining_debt <> 0 AND l.current_remaining_debt_eur IS NULL, false),
               'pill', CASE l.flag
                   WHEN 'paused' THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                                          'text', core.fn_ui_tpl('finance.app.loans.paused'))
                   WHEN 'ends'   THEN jsonb_build_object('state', 'warn', 'icon', 'calendar',
                                          'text', core.fn_ui_tpl('finance.app.loans.fixed_ends',
                                              jsonb_build_object('date', core.fn_ui_date(l.interest_rate_fixed_until))))
                   WHEN 'ended'  THEN jsonb_build_object('state', 'warn', 'icon', 'calendar',
                                          'text', core.fn_ui_tpl('finance.app.loans.fixed_ended',
                                              jsonb_build_object('date', core.fn_ui_date(l.interest_rate_fixed_until))))
                   END,
               'progress', CASE WHEN l.original_amount > 0 AND l.current_remaining_debt IS NOT NULL THEN
                   jsonb_build_object('pct', round(100 * GREATEST(l.original_amount - abs(l.current_remaining_debt), 0)
                                                   / l.original_amount, 1), 'state', 'neutral') END,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) FROM (
                   SELECT 0 AS o, jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_lender'),
                              'value', l.lender) AS d
                    WHERE l.lender IS NOT NULL
                   UNION ALL
                   SELECT 1, jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_borrower'),
                              'value', COALESCE(to_jsonb(l.borrower_name), core.fn_ui_tpl('finance.app.common.joint')))
                    WHERE v_hh
                   UNION ALL
                   SELECT 2, jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_amount'),
                              'value', CASE WHEN l.disbursement_date IS NOT NULL
                                            THEN core.fn_ui_tpl('finance.app.loans.d_amount_paid_out', jsonb_build_object(
                                                     'amount', core.fn_ui_money(l.original_amount, l.currency),
                                                     'date', core.fn_ui_date(l.disbursement_date)))
                                            ELSE core.fn_ui_money(l.original_amount, l.currency) END)
                    WHERE l.original_amount IS NOT NULL
                   UNION ALL
                   SELECT 3, jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_repaid'),
                              'value', core.fn_ui_tpl('finance.app.loans.d_repaid_value', jsonb_build_object(
                                  'pct', core.fn_ui_num(round(100 * GREATEST(l.original_amount - abs(l.current_remaining_debt), 0)
                                                              / l.original_amount, 1), 1),
                                  'amount', core.fn_ui_money(GREATEST(l.original_amount - abs(l.current_remaining_debt), 0),
                                                             l.currency))))
                    WHERE l.original_amount > 0 AND l.current_remaining_debt IS NOT NULL
                   UNION ALL
                   SELECT 4, jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_split'),
                              'value', core.fn_ui_tpl('finance.app.loans.d_split_value', jsonb_build_object(
                                  'interest', core.fn_ui_money(LEAST(l.monthly_interest_current, l.monthly_annuity), l.currency),
                                  'principal', core.fn_ui_money(GREATEST(l.monthly_principal_current, 0), l.currency))))
                    WHERE l.status = 'active' AND l.monthly_annuity IS NOT NULL AND l.monthly_interest_current IS NOT NULL
                   UNION ALL
                   SELECT 5, jsonb_build_object(
                              'label', CASE WHEN l.interest_rate_fixed_until < v_today
                                            THEN core.fn_ui_tpl('finance.app.loans.fixed_ended', jsonb_build_object(
                                                     'date', core.fn_ui_date(l.interest_rate_fixed_until)))
                                            ELSE core.fn_ui_tpl('finance.app.loans.d_fixed', jsonb_build_object(
                                                     'date', core.fn_ui_date(l.interest_rate_fixed_until))) END,
                              'value', CASE WHEN l.balance_at_fixed_until_projected IS NOT NULL
                                            THEN core.fn_ui_tpl('finance.app.loans.d_rest', jsonb_build_object(
                                                     'rest', core.fn_ui_money(abs(l.balance_at_fixed_until_projected), l.currency))) END)
                    WHERE l.interest_rate_fixed_until IS NOT NULL
                   UNION ALL
                   SELECT 6, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.loans.d_term', jsonb_build_object(
                                           'date', core.fn_ui_date(l.term_end_date))),
                              'value', CASE WHEN l.balance_at_term_end_projected IS NOT NULL
                                            THEN core.fn_ui_tpl('finance.app.loans.d_rest', jsonb_build_object(
                                                     'rest', core.fn_ui_money(abs(l.balance_at_term_end_projected), l.currency))) END)
                    WHERE l.term_end_date IS NOT NULL
                   UNION ALL
                   SELECT 7, jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_payoff'),
                              'value', core.fn_ui_date(l.payoff_date_projected))
                    WHERE l.payoff_date_projected IS NOT NULL
                   UNION ALL
                   SELECT 8, jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_interest_left'),
                              'value', core.fn_ui_tpl('finance.app.loans.d_approx', jsonb_build_object(
                                  'amount', core.fn_ui_money(l.interest_remaining_projected, l.currency))))
                    WHERE l.interest_remaining_projected IS NOT NULL) x)
            ) AS item
          FROM l
    )
    SELECT COALESCE(jsonb_agg(it.item ORDER BY abs(it.current_remaining_debt_eur) DESC NULLS LAST, it.name)
                    FILTER (WHERE NOT it.kid), '[]'::jsonb),
           COALESCE(jsonb_agg(it.item ORDER BY abs(it.current_remaining_debt_eur) DESC NULLS LAST, it.name)
                    FILTER (WHERE it.kid), '[]'::jsonb),
           COALESCE(abs(sum(it.current_remaining_debt_eur) FILTER (WHERE NOT it.kid)), 0),
           COALESCE(bool_or(it.current_remaining_debt <> 0 AND it.current_remaining_debt_eur IS NULL)
                    FILTER (WHERE NOT it.kid), false),
           -- Summen nur ohne fehlenden Wechselkurs (sonst waeren sie still zu niedrig): NULL -> entfaellt
           CASE WHEN NOT COALESCE(bool_or(it.current_remaining_debt <> 0 AND it.current_remaining_debt_eur IS NULL)
                                  FILTER (WHERE it.kid), false)
                THEN abs(sum(it.current_remaining_debt_eur) FILTER (WHERE it.kid)) END,
           CASE WHEN NOT COALESCE(bool_or(finance.fn_to_eur(it.monthly_annuity, it.currency) IS NULL)
                                  FILTER (WHERE NOT it.kid AND it.status = 'active'), false)
                THEN sum(finance.fn_to_eur(it.monthly_annuity, it.currency)) FILTER (WHERE NOT it.kid AND it.status = 'active') END,
           sum(finance.fn_to_eur(LEAST(it.monthly_interest_current, it.monthly_annuity), it.currency))
               FILTER (WHERE NOT it.kid AND it.status = 'active')
      INTO v_items, v_kids, v_total, v_gap, v_kid_sum, v_rate, v_interest
      FROM it;

    v_sections := jsonb_build_array(jsonb_build_object(
        'title', core.fn_ui_tpl('finance.app.loans.section'),
        'value', NULL,
        'empty', core.fn_ui_tpl('finance.app.loans.empty'), 'items', v_items));
    IF jsonb_array_length(v_kids) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.common.kids_not_in_sum'),
            'value', CASE WHEN v_kid_sum IS NOT NULL THEN core.fn_ui_money(v_kid_sum, 'EUR') END,
            'empty', core.fn_ui_tpl('finance.app.loans.empty'), 'items', v_kids);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.loans.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.loans.hero'),
            'value', core.fn_ui_money(v_total, 'EUR'),
            'gap', v_gap,
            'note', CASE WHEN v_rate > 0 AND v_interest IS NOT NULL THEN core.fn_ui_tpl('finance.app.loans.hero_note', jsonb_build_object(
                             'rate', core.fn_ui_money(v_rate, 'EUR'),
                             'interest', core.fn_ui_money(v_interest, 'EUR'))) END),
        'banners', '[]'::jsonb,
        'sections', v_sections);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_loans(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
