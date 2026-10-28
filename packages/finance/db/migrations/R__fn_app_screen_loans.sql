-- ============================================================
-- finance.fn_app_screen_loans(p jsonb) — Mini-App-Bildschirm „Kredite“ (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Vertrag wie finance.fn_app_screen_overview.
--   Quelle finance.loan_overview, nur ausstehende Kredite (finance.fn_loan_is_outstanding = active + paused). Je Kredit:
--   Rohname, Restschuld positiv in Kontowaehrung, „Rate · Zins“, gap wie loan_summary (Restschuld ohne Kurs), Balken
--   „getilgt“ nur mit Kreditbetrag (Prozent rechnet die DB). Hero = Restschuld gesamt in EUR.
--   Pille (Prioritaet warn vor neutral): Zinsbindung endet in [heute, heute + finance.fixed_rate_warn_months) -> warn +
--   Banner (mit voraussichtlicher Restschuld zum Bindungsende, wenn loan_overview sie kennt), auch wenn pausiert; Bindung
--   schon abgelaufen -> warn ohne Banner (das Datum ist evtl. nur nicht nachgepflegt); sonst pausiert -> neutral.
--   ZERO-TRUST-SICHTBARKEIT (core.fn_app_sees_household): owner/partner sehen alle; sonst nur borrower_person_id = ich
--   (Haushaltskredit mit NULL bleibt unsichtbar). Keine Kontonamen, keine IDs, kein Kreditgeber in der Antwort.
--   params.probe = true -> {ok, empty, banners}. Fehler als Daten, nie RAISE (forbidden / bad_request).
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
    v_pid     text;
    v_hh      boolean;
    v_today   date := CURRENT_DATE;
    v_warn_to date;
    v_items   jsonb;
    v_banners jsonb;
    v_total   numeric;
    v_gap     boolean;
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

    WITH l AS (
        SELECT lo.*,
               -- warn vor neutral: auch ein pausierter Kredit braucht die Anschlussfinanzierung
               CASE WHEN lo.interest_rate_fixed_until >= v_today AND lo.interest_rate_fixed_until < v_warn_to THEN 'ends'
                    WHEN lo.interest_rate_fixed_until < v_today THEN 'ended'
                    WHEN lo.status = 'paused' THEN 'paused' END AS flag
          FROM finance.loan_overview lo
         WHERE finance.fn_loan_is_outstanding(lo.status)
           AND (v_hh OR lo.borrower_person_id = v_pid)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', l.name,
               'sub', core.fn_ui_tpl('finance.app.loans.rate_line', jsonb_build_object(
                          'rate', core.fn_ui_money(l.monthly_annuity, l.currency),
                          'interest', core.fn_ui_num(l.interest_rate, 2))),
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
               'target', NULL)
             ORDER BY abs(l.current_remaining_debt_eur) DESC NULLS LAST, l.name), '[]'::jsonb),
           COALESCE(jsonb_agg(jsonb_build_object(
               'state', 'warn', 'icon', 'calendar',
               'text', CASE WHEN l.balance_at_fixed_until_projected IS NOT NULL
                   THEN core.fn_ui_tpl('finance.app.loans.banner_fixed_ends_rest', jsonb_build_object(
                            'name', l.name, 'date', core.fn_ui_date(l.interest_rate_fixed_until),
                            'rest', core.fn_ui_money(abs(l.balance_at_fixed_until_projected), l.currency)))
                   ELSE core.fn_ui_tpl('finance.app.loans.banner_fixed_ends', jsonb_build_object(
                            'name', l.name, 'date', core.fn_ui_date(l.interest_rate_fixed_until))) END,
               'target', jsonb_build_object('screen', 'loans', 'params', '{}'::jsonb))
             ORDER BY l.interest_rate_fixed_until, l.name) FILTER (WHERE l.flag = 'ends'), '[]'::jsonb),
           COALESCE(abs(sum(l.current_remaining_debt_eur)), 0),
           COALESCE(bool_or(l.current_remaining_debt <> 0 AND l.current_remaining_debt_eur IS NULL), false)
      INTO v_items, v_banners, v_total, v_gap
      FROM l;

    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        RETURN jsonb_build_object('ok', true, 'empty', jsonb_array_length(v_items) = 0, 'banners', v_banners);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.loans.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.loans.hero'),
            'value', core.fn_ui_money(v_total, 'EUR'),
            'gap', v_gap,
            'note', NULL),
        'banners', '[]'::jsonb,
        'sections', jsonb_build_array(
            jsonb_build_object('title', core.fn_ui_tpl('finance.app.loans.section'),
                               'empty', core.fn_ui_tpl('finance.app.loans.empty'), 'items', v_items)));
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_loans(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
