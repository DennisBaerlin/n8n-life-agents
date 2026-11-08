-- ============================================================
-- fn_advisor_snapshot (READ, STABLE) -- das Gesamtbild des Finanzberaters in EINER Abfrage (2026-11-02)
--   Befund 2026-11-01: der Plan-Knopf riss maxIterations, weil der Gateway parallele Tool-Aufrufe abschaltet und jede
--   Lese-Abfrage damit eine Iteration kostet. Der Berater liest das Bild beim ersten Pre-Fill eines Gespraechs, beim
--   Plan-Knopf und beim Plan-Review einmal hier (postgres_select, finance_ro); enge Fragen bleiben bei den Einzel-Views.
--   Die fn rechnet NICHTS: sie fasst nur zusammen, was die Views und Funktionen schon liefern.
--   Zeilen = to_jsonb(view) minus feste Entfernliste: Vertrags-/Kontonummern und notes (Freitext ohne Laengengrenze; wer
--   sie braucht, liest die Einzel-View) plus rein technische Spalten. Neue fachliche View-Spalten kommen so automatisch
--   mit; eine neue Nummern-Spalte oder eine neue finance-View faellt im Test auf (Drift-Waechter, Ausschlussliste dort).
--   valid_to entfaellt ebenfalls: es ist der erste nicht mehr gueltige Tag und wurde als letzter Termin gelesen; das Ende
--   traegt last_valid_day, bei Dauerauftraegen zusaetzlich last_execution.
--   Beendetes fehlt, Pausiertes bleibt: nur aktive Konten, Immobilien und Ziele (ein Ziel kennt keinen Status pausiert,
--   goal_status zeigt es), Vorsorge ohne ausgezahlte (pausiert = beitragsfrei, der Vertrag besteht), nur offene Kredite
--   (finance.fn_loan_is_outstanding), Sparplaene ohne beendete (Soft-Close: fn_close_savings_plan setzt pausiert + ein
--   Raten-Ende, das bei geplanter Aenderung auch in der Zukunft liegen kann; einfach pausiert hat kein Ende).
--   Kaufkraftwerte der Rente fehlen hier: sie brauchen die Plan-Inflation (eigener Aufruf von fn_pension_outlook). Darum
--   entfaellt auch real_note: der Satz „keine Inflationsannahme im Plan“ stimmt nur, wenn der Aufrufer sie kennt.
--   plpgsql: liest R__v_*-Views und alphabetisch spaetere fns (late-bound). INVOKER (finance_ro liest alle Quellen).
--   Erfasstes ist nie unsichtbar (Befund 2026-11-02): recurring traegt auch Zahlungen, deren erster Termin innerhalb eines
--   Rhythmus aussteht (starts_on, sie zaehlen), planned_recurring die, die spaeter starten (zaehlen noch nicht).
--   RUECKGABE jsonb, Listen (leer = []): persons, recurring, planned_recurring, accounts (+ has_history, everyday_per_day, everyday_per_month,
--   everyday_provisional nur an Geld-Konten), networth, savings_plans, standing_orders, loans, insurances, pensions,
--   pension_outlook, real_estate, goals (+ goal_status), depot_risk (fn_savings_goal_derisk_status je Ziel im Fenster:
--   Rat, Entscheidung accepted/acceptance_expired, letzter Check), depot_holdings, depot_performance, warnings (je Konto:
--   kind account_coverage {account, currency, lowest_balance, lowest_on, has_history} aus fn_account_outlook bzw. kind
--   savings_funding {account, currency, state warn|alert, runs_out_on, lowest_balance, lowest_on} aus
--   account_funding_overview); Objekte: cashflow_summary, parent_cashflow_summary, loan_summary, emergency_reserve
--   Tests: tests/db/finance/test_fn_advisor_snapshot.sql, tests/db/cross/test_role_permissions.sql (2-adv)
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_advisor_snapshot()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_drop CONSTANT text[] := ARRAY['account_number', 'contract_number', 'policy_number', 'notes',
                                    'holding_id', 'current_rp_id', 'head_rp_id', 'recurring_payment_id', 'valid_to'];
    v_stale CONSTANT numeric := COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'statement_stale_days'), '')::numeric, 45);
BEGIN
    RETURN jsonb_build_object(
        'persons', (SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.person_id), '[]'::jsonb)
                      FROM core.fn_household_persons() p),
        'cashflow_summary', (SELECT to_jsonb(s) FROM finance.monthly_cashflow_summary s),
        'parent_cashflow_summary', (SELECT to_jsonb(s) FROM finance.parent_cashflow_summary s),
        'recurring', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.id), '[]'::jsonb)
                        FROM finance.monthly_cashflow_overview v),
        'planned_recurring', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.starts_on, v.id), '[]'::jsonb)
                                FROM finance.upcoming_recurring_payments v
                               WHERE NOT v.counted_in_cashflow),
        'accounts', (SELECT COALESCE(jsonb_agg(
                                (to_jsonb(v) - v_drop)
                                || CASE WHEN e.account_id IS NOT NULL THEN jsonb_build_object(
                                        'has_history', e.has_history,
                                        'everyday_per_day', e.everyday_per_day,
                                        'everyday_per_month', e.everyday_per_month,
                                        'everyday_provisional', e.provisional) ELSE '{}'::jsonb END
                                ORDER BY v.id), '[]'::jsonb)
                       FROM finance.account_overview v
                       LEFT JOIN finance.account_everyday_spending e ON e.account_id = v.id
                      WHERE v.status = 'active'),
        'networth', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.bucket, v.asset_class, v.owner_person_id), '[]'::jsonb)
                       FROM finance.networth_by_asset_class v),
        'savings_plans', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.id), '[]'::jsonb)
                            FROM finance.savings_plan_overview v
                           WHERE NOT (v.status = 'paused' AND EXISTS (SELECT 1 FROM finance.recurring_payments r
                                                                       WHERE r.id = v.head_rp_id AND r.valid_to IS NOT NULL))),
        'standing_orders', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.from_account, v.name, v.recurring_payment_id), '[]'::jsonb)
                              FROM finance.standing_order_overview v),
        'loans', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.id), '[]'::jsonb)
                    FROM finance.loan_overview v
                   WHERE finance.fn_loan_is_outstanding(v.status)),
        'loan_summary', (SELECT to_jsonb(s) FROM finance.loan_summary s),
        'insurances', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.id), '[]'::jsonb)
                         FROM finance.active_insurances v),
        'pensions', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.id), '[]'::jsonb)
                       FROM finance.pension_overview v
                      WHERE v.status <> 'paid_out'),
        'pension_outlook', (SELECT COALESCE(jsonb_agg(x.e - 'real_note' ORDER BY x.n), '[]'::jsonb)
                              FROM jsonb_array_elements(finance.fn_pension_outlook('{}'::jsonb)->'pensions') WITH ORDINALITY x(e, n)),
        'real_estate', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.id), '[]'::jsonb)
                          FROM finance.real_estate_overview v
                         WHERE v.status = 'active'),
        'goals', (SELECT COALESCE(jsonb_agg((to_jsonb(v) - v_drop)
                                            || jsonb_build_object('goal_status', finance.fn_savings_goal_pace(v.id))
                                            ORDER BY v.id), '[]'::jsonb)
                    FROM finance.savings_goal_progress v
                   WHERE v.status = 'active'),
        'emergency_reserve', finance.fn_emergency_reserve_status(),
        -- Sparziel kurz vor dem Termin im Depot (2026-11-06): Glide Path + bewusste Entscheidung je Ziel im Fenster
        -- (accepted = der Nutzer hat das Risiko bewusst angenommen -> hoechstens ein Satz, kein Vorschlag)
        'depot_risk', (SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.goal_id), '[]'::jsonb)
                         FROM finance.fn_savings_goal_derisk_status() d WHERE d.in_window),
        'depot_holdings', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.account_id, v.id), '[]'::jsonb)
                             FROM finance.depot_holdings_overview v),
        'depot_performance', (SELECT COALESCE(jsonb_agg(to_jsonb(v) - v_drop ORDER BY v.is_total, v.account_id), '[]'::jsonb)
                                FROM finance.depot_performance v),
        -- Ohne Auszug zaehlt nur ein Minus: die festen Zahlungen allein reichen dann schon, der fehlende Alltag kaeme dazu;
        -- ein blosses Unterschreiten des Puffers waere Halbwissen (Regel fn_coverage_accounts). Veralteter Auszug: die
        -- Vorschau ist nicht belastbar, fn_advisor_review meldet ihn statt der Unterdeckung.
        'warnings', (SELECT COALESCE(jsonb_agg(w.e ORDER BY w.ord, w.account_id), '[]'::jsonb)
                       FROM (SELECT 1 AS ord, a.id AS account_id, jsonb_build_object(
                                    'kind', 'account_coverage', 'account', a.name, 'currency', a.currency,
                                    'lowest_balance', (j.o->>'min_projected')::numeric, 'lowest_on', (j.o->>'min_date')::date,
                                    'has_history', (j.o->>'has_history')::boolean) AS e
                               FROM finance.accounts a
                              CROSS JOIN LATERAL finance.fn_account_outlook(a.id) AS j(o)
                              WHERE a.status = 'active' AND a.account_type = 'cash' AND (j.o->>'ok')::boolean
                                AND CASE WHEN (j.o->>'has_history')::boolean
                                         THEN (j.o->>'shortfall')::numeric > 0
                                              AND COALESCE((j.o->>'statement_age_days')::numeric, 0) <= v_stale
                                         ELSE (j.o->>'min_projected')::numeric < 0 END
                             UNION ALL
                             SELECT 2, f.account_id, jsonb_build_object(
                                    'kind', 'savings_funding', 'account', f.account_name, 'currency', f.currency, 'state', f.state,
                                    'runs_out_on', f.runs_out_on, 'lowest_balance', f.min_projected, 'lowest_on', f.min_date)
                               FROM finance.account_funding_overview f
                              WHERE f.state IN ('warn', 'alert')) w));
END;
$$;
