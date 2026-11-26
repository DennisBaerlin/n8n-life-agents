-- ============================================================
-- finance.fn_advisor_hints(p_domain) — Kontohinweise des Finanzberaters mit fester Klasse (READ, STABLE)
--   Die eine Adresse fuer Berater-Warnungen (finance.fn_advisor_snapshot liest sie hier, core.fn_advisor_hint_prompt als
--   core.advisors.hints_fn). Die Klasse entscheidet die DB, nicht das Modell:
--     urgent        das Problem-Datum ist bald (finance.fn_warning_due_soon) -> im Plan-Gespraech als Frage der Art hint,
--                   auch wenn eine Vormerkung das Konto nennt (Geld fehlt bald: das Eintragen wartet nicht bis nach dem Plan);
--     entry         nicht bald, aber eine offene Vormerkung nennt das Konto (core.fn_advisor_handoff_mentions): der Hinweis
--                   verschwindet mit dem Eintragen und gehoert dorthin;
--     after_plan    alles andere (Puffer unterschritten, Engpass weiter weg) -> erst nach dem Plan;
--     monthly_check Kontoauszug aelter als finance.statement_stale_days: die Vorschau ist nicht belastbar, der Monats-Check
--                   holt den Auszug ab (nie vom Berater angesprochen).
--   Eintraege: account_coverage (aktive Geld-Konten) {account, account_label, currency, lowest_balance, lowest_on,
--     has_history, due_soon} aus fn_account_outlook (mit Auszug: Unterschreitung des Puffers; ohne Auszug nur ein Minus);
--     savings_funding {account, account_label, currency, state warn|alert, runs_out_on, lowest_balance, lowest_on, due_soon}
--     aus account_funding_overview (Deckungs-Konten jeder Art); statement_stale {account, account_label, statement_age_days}
--     (aktive Geld-Konten). Jeder Eintrag zusaetzlich key ('<kind>:<account_id>', fest fuer den Merker "spaeter"), class,
--     pending_entry (eine offene Vormerkung nennt das Konto),
--     text_key + params fuer die Hinweis-Karte ({account, amount, currency, date}; bei statement_stale nur {account}) (Betrag = fehlender Betrag bzw. tiefster Stand, Datum = Problem-Datum).
--   Eingabe p_domain (Domaene der Vormerkungen, Default finance). Rueckgabe jsonb-Array (Reihenfolge: coverage, funding,
--   stale; je Konto-id). INVOKER (finance_ro liest alle Quellen, core nur ueber Fenster), plpgsql (late-bound).
--   Tests: tests/db/finance/test_fn_advisor_hints.sql, tests/db/finance/test_fn_advisor_snapshot.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_advisor_hints(p_domain text DEFAULT 'finance')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_stale CONSTANT numeric := COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'statement_stale_days'), '')::numeric, 45);
    v_raw   jsonb;
    v_named text[];
BEGIN
    -- Die Kontovorschau ist teuer: einmal je Geld-Konto (CTE o), beide Zweige lesen daraus.
    WITH o AS (SELECT a.id, a.name, a.emoji, a.account_type, a.currency, j.o
                 FROM finance.accounts a CROSS JOIN LATERAL finance.fn_account_outlook(a.id) AS j(o)
                WHERE a.status = 'active' AND a.account_type = 'cash' AND (j.o->>'ok')::boolean)
    SELECT COALESCE(jsonb_agg(w.e ORDER BY w.ord, w.account_id), '[]'::jsonb) INTO v_raw
      FROM (SELECT 1 AS ord, a.id AS account_id, jsonb_build_object(
                   'key', 'account_coverage:' || a.id, 'kind', 'account_coverage', 'account', a.name,
                   'account_label', finance.fn_account_label(a.emoji, a.account_type, a.name), 'currency', a.currency,
                   'lowest_balance', (j.o->>'min_projected')::numeric, 'lowest_on', (j.o->>'min_date')::date,
                   'has_history', (j.o->>'has_history')::boolean,
                   'due_soon', finance.fn_warning_due_soon((j.o->>'min_date')::date),
                   'text_key', 'finance.hint.account_short',
                   'params', jsonb_build_object('account', finance.fn_account_label(a.emoji, a.account_type, a.name),
                       'amount', greatest(-(j.o->>'min_projected')::numeric, COALESCE((j.o->>'shortfall')::numeric, 0)),
                       'currency', a.currency, 'date', (j.o->>'min_date')::date)) AS e
              FROM o AS a CROSS JOIN LATERAL (SELECT a.o) AS j(o)
             WHERE CASE WHEN (j.o->>'has_history')::boolean
                        THEN (j.o->>'shortfall')::numeric > 0
                             AND COALESCE((j.o->>'statement_age_days')::numeric, 0) <= v_stale
                        ELSE (j.o->>'min_projected')::numeric < 0 END
            UNION ALL
            SELECT 2, f.account_id, jsonb_build_object(
                   'key', 'savings_funding:' || f.account_id, 'kind', 'savings_funding', 'account', f.account_name,
                   'account_label', (SELECT finance.fn_account_label(x.emoji, x.account_type, x.name) FROM finance.accounts x WHERE x.id = f.account_id),
                   'currency', f.currency, 'state', f.state,
                   'runs_out_on', f.runs_out_on, 'lowest_balance', f.min_projected, 'lowest_on', f.min_date,
                   'due_soon', finance.fn_warning_due_soon(LEAST(f.runs_out_on, f.min_date)),
                   'text_key', 'finance.hint.funding_runs_out',
                   'params', jsonb_build_object('account', (SELECT finance.fn_account_label(x.emoji, x.account_type, x.name) FROM finance.accounts x WHERE x.id = f.account_id),
                       'amount', greatest(-f.min_projected, 0), 'currency', f.currency, 'date', LEAST(f.runs_out_on, f.min_date)))
              FROM finance.account_funding_overview f
             WHERE f.state IN ('warn', 'alert')
            UNION ALL
            SELECT 3, a.id, jsonb_build_object(
                   'key', 'statement_stale:' || a.id, 'kind', 'statement_stale', 'account', a.name,
                   'account_label', finance.fn_account_label(a.emoji, a.account_type, a.name),
                   'statement_age_days', (j.o->>'statement_age_days')::numeric, 'due_soon', false,
                   'text_key', 'finance.hint.statement_stale',
                   'params', jsonb_build_object('account', finance.fn_account_label(a.emoji, a.account_type, a.name)))
              FROM o AS a CROSS JOIN LATERAL (SELECT a.o) AS j(o)
             WHERE (j.o->>'has_history')::boolean AND COALESCE((j.o->>'statement_age_days')::numeric, 0) > v_stale) w;

    v_named := core.fn_advisor_handoff_mentions(p_domain,
                   ARRAY(SELECT e->>'account' FROM jsonb_array_elements(v_raw) e WHERE e->>'kind' <> 'statement_stale'));
    RETURN COALESCE((SELECT jsonb_agg(e || jsonb_build_object('class', CASE
                                 WHEN e->>'kind' = 'statement_stale' THEN 'monthly_check'
                                 WHEN (e->>'due_soon')::boolean THEN 'urgent'
                                 WHEN e->>'account' = ANY (v_named) THEN 'entry'
                                 ELSE 'after_plan' END,
                             'pending_entry', e->>'kind' <> 'statement_stale' AND e->>'account' = ANY (v_named)) ORDER BY n)
                       FROM jsonb_array_elements(v_raw) WITH ORDINALITY AS x(e, n)), '[]'::jsonb);
END;
$$;
