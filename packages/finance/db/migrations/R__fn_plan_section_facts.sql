-- ============================================================
-- finance.fn_plan_section_facts(p_section_key, p_chat_id) — "Stand heute" je Teil des Finanzplans (READ, STABLE)
--   Ist-Fakten gehoeren nicht in den Plan-Text (sie veralten), sondern werden bei jeder Anzeige frisch gezeigt: Kopf der
--   Themen-Karte (core.fn_render_prompt ueber core.advisors.section_facts_fn). Quellen sind dieselben Views/fns wie finance.fn_advisor_snapshot; die fn rechnet nichts Neues.
--   Je Teil hoechstens sechs Zeilen {label, value, kind (money|count|text)}, fertig in der Sprache der Person des Chats
--   (agent.fn_person_lang, Betraege core.fn_fmt_money, Daten core.fn_ui_date):
--     household_basics  Personen (Erwachsene, Kinder), Einnahmen, feste Ausgaben, frei im Monat (monthly_cashflow_summary)
--     risk_protection   je aktive Versicherung: Beitrag im Monat
--     emergency_reserve mit Notreserve: Stand, Ziel, reicht fuer n Monate; ohne: Monatsausgaben (fn_emergency_reserve_status)
--     debts_loans       je offener Kredit (fn_loan_is_outstanding): Rest, Rate, Zinsbindung bis
--     retirement_pension je Vorsorge (nicht ausgezahlt): garantierte Monatsrente, sonst aktueller Wert
--     wealth_building   Depot, Konten, Festgeld, Sonstiges aus networth_by_asset_class; Geld der Kinder zaehlt nicht mit
--     goals_triggers    je aktives Sparziel: Stand von Ziel
--     risk_profile, crossborder und unbekannte Teile: []
--   Absender nicht aufgeloest oder Kind -> [] (Haushaltszahlen nur fuer Erwachsene).
--   INVOKER (Host-Cred des Renderers), plpgsql (late-bound).
--   Tests: tests/db/finance/test_fn_plan_section_facts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_plan_section_facts(p_section_key text, p_chat_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sender jsonb;
    v_lang   text;
    v_rows   jsonb := '[]'::jsonb;
    v_cf     record;
    v_er     jsonb;
    v_kids   text[];
BEGIN
    v_sender := core.fn_chat_person(p_chat_id);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE OR v_sender->>'role' = 'child' THEN
        RETURN '[]'::jsonb;
    END IF;
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';
    v_kids := ARRAY(SELECT hp.person_id FROM core.fn_household_persons() hp WHERE hp.role = 'child');

    IF p_section_key = 'household_basics' THEN
        SELECT * INTO v_cf FROM finance.monthly_cashflow_summary;
        v_rows := jsonb_build_array(jsonb_build_object('label', core.fn_ui_text('finance.facts.persons', v_lang),
                      'value', core.fn_ui_text('finance.facts.persons_value', v_lang, jsonb_build_object(
                          'adults', (SELECT count(*) FROM core.fn_household_persons() hp WHERE hp.role IS DISTINCT FROM 'child'),
                          'children', cardinality(v_kids))), 'kind', 'count'))
               || CASE WHEN v_cf IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(
                      jsonb_build_object('label', core.fn_ui_text('finance.facts.income', v_lang),
                                         'value', core.fn_fmt_money(v_cf.monthly_income, 'EUR', v_lang), 'kind', 'money'),
                      jsonb_build_object('label', core.fn_ui_text('finance.facts.obligations', v_lang),
                                         'value', core.fn_fmt_money(v_cf.monthly_obligations, 'EUR', v_lang), 'kind', 'money'),
                      jsonb_build_object('label', core.fn_ui_text('finance.facts.free', v_lang),
                                         'value', core.fn_fmt_money(v_cf.monthly_free, 'EUR', v_lang), 'kind', 'money')) END;
    ELSIF p_section_key = 'risk_protection' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('label', i.name,
                   'value', core.fn_ui_text('finance.facts.per_month', v_lang, jsonb_build_object('amount', core.fn_fmt_money(i.monthly_equivalent, 'EUR', v_lang))),
                   'kind', 'money') ORDER BY i.monthly_equivalent DESC NULLS LAST, i.id), '[]'::jsonb)
          INTO v_rows FROM (SELECT * FROM finance.active_insurances ORDER BY monthly_equivalent DESC NULLS LAST, id LIMIT 6) i;
    ELSIF p_section_key = 'emergency_reserve' THEN
        v_er := finance.fn_emergency_reserve_status();
        IF (v_er->>'exists')::boolean THEN
            v_rows := jsonb_build_array(
                jsonb_build_object('label', core.fn_ui_text('finance.facts.reserve_now', v_lang),
                                   'value', core.fn_fmt_money((v_er->>'covered_eur')::numeric, 'EUR', v_lang), 'kind', 'money'),
                jsonb_build_object('label', core.fn_ui_text('finance.facts.reserve_target', v_lang),
                                   'value', core.fn_fmt_money((v_er->>'target_eur')::numeric, 'EUR', v_lang), 'kind', 'money'))
                || CASE WHEN COALESCE((v_er->'basis'->>'monthly_eur')::numeric, 0) > 0 THEN jsonb_build_array(
                       jsonb_build_object('label', core.fn_ui_text('finance.facts.reserve_months', v_lang),
                           'value', core.fn_ui_text('finance.facts.months_value', v_lang, jsonb_build_object('n',
                               floor((v_er->>'covered_eur')::numeric / (v_er->'basis'->>'monthly_eur')::numeric)::int)), 'kind', 'count'))
                   ELSE '[]'::jsonb END;
        ELSIF (v_er->'basis'->>'monthly_eur') IS NOT NULL THEN
            v_rows := jsonb_build_array(jsonb_build_object('label', core.fn_ui_text('finance.facts.monthly_spending', v_lang),
                          'value', core.fn_fmt_money((v_er->'basis'->>'monthly_eur')::numeric, 'EUR', v_lang), 'kind', 'money'));
        END IF;
    ELSIF p_section_key = 'debts_loans' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('label', l.name,
                   'value', CASE WHEN l.interest_rate_fixed_until IS NULL
                                 THEN core.fn_ui_text('finance.facts.loan_value', v_lang, jsonb_build_object(
                                          'rest', core.fn_fmt_money(l.current_remaining_debt, l.currency, v_lang),
                                          'rate', core.fn_fmt_money(l.monthly_annuity, l.currency, v_lang)))
                                 ELSE core.fn_ui_text('finance.facts.loan_value_fixed', v_lang, jsonb_build_object(
                                          'rest', core.fn_fmt_money(l.current_remaining_debt, l.currency, v_lang),
                                          'rate', core.fn_fmt_money(l.monthly_annuity, l.currency, v_lang),
                                          'until', core.fn_ui_date(l.interest_rate_fixed_until))) END,
                   'kind', 'money') ORDER BY l.id), '[]'::jsonb)
          INTO v_rows FROM (SELECT * FROM finance.loan_overview v WHERE finance.fn_loan_is_outstanding(v.status) ORDER BY v.id LIMIT 6) l;
    ELSIF p_section_key = 'retirement_pension' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('label', x.name,
                   'value', CASE WHEN x.guaranteed_monthly_pension IS NOT NULL
                                 THEN core.fn_ui_text('finance.facts.pension_monthly', v_lang, jsonb_build_object('amount', core.fn_fmt_money(x.guaranteed_monthly_pension, 'EUR', v_lang)))
                                 WHEN x.current_value IS NOT NULL
                                 THEN core.fn_ui_text('finance.facts.pension_value', v_lang, jsonb_build_object('amount', core.fn_fmt_money(x.current_value, 'EUR', v_lang)))
                                 ELSE '—' END,
                   'kind', 'money') ORDER BY x.id), '[]'::jsonb)
          INTO v_rows FROM (SELECT * FROM finance.pension_overview v
                             WHERE v.status <> 'paid_out' AND NOT (v.owner_person_id = ANY (v_kids)) IS TRUE ORDER BY v.id LIMIT 6) x;
    ELSIF p_section_key = 'wealth_building' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('label', core.fn_ui_text(g.label_key, v_lang),
                   'value', core.fn_fmt_money(g.eur, 'EUR', v_lang), 'kind', 'money') ORDER BY g.ord), '[]'::jsonb)
          INTO v_rows
          FROM (SELECT CASE n.bucket WHEN 'depot' THEN 1 WHEN 'cash' THEN 2 WHEN 'fixed_deposit' THEN 3 ELSE 4 END AS ord,
                       CASE n.bucket WHEN 'depot' THEN 'finance.facts.wealth_depot' WHEN 'cash' THEN 'finance.facts.wealth_cash'
                                     WHEN 'fixed_deposit' THEN 'finance.facts.wealth_fixed' ELSE 'finance.facts.wealth_other' END AS label_key,
                       sum(n.value_eur) AS eur
                  FROM finance.networth_by_asset_class n
                 WHERE NOT (n.owner_person_id = ANY (v_kids)) IS TRUE AND n.value_eur IS NOT NULL
                 GROUP BY 1, 2 HAVING sum(n.value_eur) <> 0) g;
    ELSIF p_section_key = 'goals_triggers' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('label', s.name,
                   'value', core.fn_ui_text('finance.facts.goal_value', v_lang, jsonb_build_object(
                       'current', core.fn_fmt_money(s.current_amount, 'EUR', v_lang),
                       'target', core.fn_fmt_money(s.target_amount, 'EUR', v_lang))),
                   'kind', 'money') ORDER BY s.id), '[]'::jsonb)
          INTO v_rows FROM (SELECT * FROM finance.savings_goal_progress v WHERE v.status = 'active'
                             AND NOT (v.beneficiary_person_id = ANY (v_kids)) IS TRUE ORDER BY v.id LIMIT 6) s;
    END IF;
    RETURN (SELECT COALESCE(jsonb_agg(e ORDER BY n), '[]'::jsonb) FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS x(e, n) WHERE n <= 6);
END;
$$;
