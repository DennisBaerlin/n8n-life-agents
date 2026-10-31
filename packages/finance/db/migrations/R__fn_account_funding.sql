-- ============================================================
-- fn_account_funding (READ, STABLE, RAISE-frei) -- Spar-Deckung eines Kontos: reicht das Geld fuer seine Dauerauftraege
--   und Sparplaene? Andere Frage als fn_account_outlook („reicht es bis zum naechsten Geldeingang, mit Puffer"):
--   Horizont finance.funding_horizon_months (Default 24), kein Puffer, keine Zinsen (P2P/Festgeld -> eher vorsichtig).
--   Tagesreihe = finance.fn_account_projection ab d0 (Tag nach dem bestaetigten Stand, sonst heute), ausgewertet ab heute.
--   SCHWELLE = Ziel-Geld des Kontos je Tag (UX-Gesamtkonzept 2026-10-31, Bug B1 „Ziel-Geld ist nicht frei“): Start =
--   Ziel-Geld heute (Saldo - finance.fn_account_free_balance), auf den Saldo gedeckelt (eine bestehende Ueber-Zuordnung
--   ist keine Luecke der Zukunft, die App zeigt sie am Stand); minus die Ausfuehrungen ziel-verknuepfter Sparplaene von
--   diesem Konto (verbrauchen ihr Ziel-Geld, je Ziel hoechstens sein Anteil hier); plus eingehende Ziel-Raten (neues
--   Ziel-Geld). Ohne Ziel-Geld = 0 (darunter platzt die Ausfuehrung).
--   Alltagsausgaben (everyday): ein reines Spar-/Verrechnungskonto hat keine ('none'). Hat das Konto Abgaenge, die weder
--   Uebertrag noch Sparplan/Sparziel/Vorsorge sind (Miete, Strom, Kredit -> Ausgabenkonto), zaehlt die Schaetzung aus den
--   Auszuegen netto (fn_account_everyday_per_day.per_day_net, 'estimated'); ohne Auszug ist sie unbekannt ('unknown')
--   -> neutral statt eines falschen „gedeckt" (ein Gehaltskonto mit Kartenzahlungen sahe sonst immer gruen aus).
--   Gewollter Abbau aus Guthaben ist keine Luecke (arch-challenge 2026-10-29, ohne Markierung durch den Nutzer):
--     alert = Stand faellt innerhalb von finance.funding_alert_months (Default 3, gedeckelt auf den Horizont) unter die
--             Schwelle,
--     warn  = innerhalb des Horizonts (runs_out_on = erster Tag unter der Schwelle), ok sonst,
--     neutral = Kurs fehlt (fx_gap) oder Alltagsausgaben unbekannt.
--   p_alert_only = true (probe beim App-Start): rechnet nur das alert-Fenster (billig); die Fenster-Regel lebt nur hier.
--   monthly_in/out = Summe von finance.fn_account_flows (je Kette das massgebliche Glied) in Kontowaehrung.
--   Konsumenten: fn_account_low_state (Konten-Tab, Spiegel-Pille am Sparplan), fn_savings_funding_fold,
--   finance.account_funding_overview.
--   RUECKGABE: {ok, account_id, currency, balance, monthly_in, monthly_out, everyday, everyday_per_day, min_projected
--   (absoluter tiefster Stand), min_date, runs_out_on, horizon_end, state, fx_gap, reserved (Ziel-Geld am Start),
--   min_free (tiefster Stand minus Schwelle), min_free_date (sein Tag)} | {ok:false, reason} (Kreditkonto, unbekannt)
--   Tests: tests/db/finance/test_fn_account_funding.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_funding(p_account_id int, p_alert_only boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_acct     finance.accounts%ROWTYPE;
    v_today    DATE := CURRENT_DATE;
    v_d0       DATE;
    v_months   INT;
    v_alert    INT;
    v_until    DATE;
    v_spend    BOOLEAN;
    v_hist     BOOLEAN;
    v_per_day  NUMERIC := 0;
    v_everyday TEXT := 'none';
    v_bal      NUMERIC;
    v_min      NUMERIC;
    v_min_date DATE;
    v_out_on   DATE;
    v_gap      BOOLEAN;
    v_in       NUMERIC;
    v_out      NUMERIC;
    v_fgap     BOOLEAN;
    v_state    TEXT;
    v_res      NUMERIC;   -- Ziel-Geld heute (Schwelle am Start, auf den Saldo gedeckelt)
    v_now      NUMERIC;
    v_min_free NUMERIC;
    v_free_date DATE;
BEGIN
    SELECT * INTO v_acct FROM finance.accounts WHERE id = p_account_id;
    IF NOT FOUND OR v_acct.account_type = 'loan' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Funding is only available for non-loan accounts.');
    END IF;
    v_months := GREATEST(COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'funding_horizon_months'), '')::int, 24), 1);
    v_alert  := LEAST(GREATEST(COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'funding_alert_months'), '')::int, 3), 1),
                      v_months);
    IF p_alert_only THEN
        v_months := v_alert;
    END IF;
    v_d0    := COALESCE(v_acct.last_reconciled_at + 1, v_today);
    v_until := (v_today + make_interval(months => v_months))::date;

    SELECT round(COALESCE(sum(f.monthly) FILTER (WHERE f.side = 'in'), 0), 2),
           round(COALESCE(sum(f.monthly) FILTER (WHERE f.side = 'out'), 0), 2),
           COALESCE(bool_or(f.monthly IS NULL), false),
           COALESCE(bool_or(f.side = 'out' AND r.target_account_id IS NULL
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_plans sp WHERE sp.recurring_payment_id = h.head)
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_goals g WHERE g.recurring_payment_id = h.head)
                            AND NOT EXISTS (SELECT 1 FROM finance.pension p WHERE p.recurring_payment_id = h.head)), false)
    INTO v_in, v_out, v_fgap, v_spend
    FROM finance.fn_account_flows(p_account_id) f
    JOIN finance.recurring_payments r ON r.id = f.rp_id
    CROSS JOIN LATERAL (SELECT finance.fn_recurring_lineage_head(r.id) AS head) h;

    IF v_spend THEN
        SELECT e.per_day_net, e.has_history INTO v_per_day, v_hist FROM finance.fn_account_everyday_per_day(p_account_id) e;
        v_everyday := CASE WHEN v_hist THEN 'estimated' ELSE 'unknown' END;
    END IF;

    -- Schwelle = Ziel-Geld auf dem Konto (fn_account_free_balance: Saldo - frei), Start auf den Saldo gedeckelt (eine
    -- schon bestehende Ueber-Zuordnung zeigt die App als Pille am Stand, sie ist keine Luecke der Zukunft)
    SELECT COALESCE(GREATEST(b.balance - finance.fn_account_free_balance(p_account_id), 0), 0), COALESCE(b.balance, 0)
      INTO v_res, v_now
      FROM finance.accounts a LEFT JOIN finance.account_balances b ON b.account_id = a.id WHERE a.id = p_account_id;
    v_res := LEAST(COALESCE(v_res, 0), GREATEST(COALESCE(v_now, 0), 0));

    WITH s AS (
        SELECT * FROM finance.fn_account_projection(p_account_id, v_d0, v_until, v_per_day)
    ), f AS (
        -- je Vorkommen: Abfluss eines ziel-verknuepften Sparplans (verbraucht das Ziel-Geld seines Ziels) bzw. Zufluss
        -- einer Ziel-Rate (neues Ziel-Geld, nicht frei)
        SELECT pf.due_date, pf.amount, sp.savings_goal_id AS g_out, sg.id AS g_in
          FROM finance.fn_account_planned_flows(p_account_id, v_d0, v_until) pf
         CROSS JOIN LATERAL (SELECT finance.fn_recurring_lineage_head(pf.recurring_payment_id) AS head) h
          LEFT JOIN finance.savings_plans sp ON pf.amount < 0 AND sp.recurring_payment_id = h.head AND sp.savings_goal_id IS NOT NULL
          LEFT JOIN finance.savings_goals sg ON pf.amount > 0 AND sg.recurring_payment_id = h.head AND sg.status = 'active'
    ), sh AS (
        SELECT gs.goal_id, GREATEST(gs.share_native, 0) AS share
          FROM finance.savings_goal_account_share gs
         WHERE gs.account_id = p_account_id AND gs.goal_status = 'active'
    ), st AS (
        SELECT s.day, s.bal, s.fx_gap,
               GREATEST(v_res
                   - COALESCE((SELECT sum(LEAST(sh.share, c.cum))
                                 FROM (SELECT f.g_out, sum(-f.amount) AS cum FROM f
                                        WHERE f.g_out IS NOT NULL AND f.due_date <= s.day GROUP BY f.g_out) c
                                 JOIN sh ON sh.goal_id = c.g_out), 0)
                   + COALESCE((SELECT sum(f.amount) FROM f WHERE f.g_in IS NOT NULL AND f.due_date <= s.day), 0), 0) AS thr
          FROM s
    )
    SELECT (SELECT st.bal FROM st WHERE st.day = GREATEST(v_today, v_d0)),
           (SELECT st.bal FROM st WHERE st.day >= v_today ORDER BY st.bal, st.day LIMIT 1),
           (SELECT st.day FROM st WHERE st.day >= v_today ORDER BY st.bal, st.day LIMIT 1),
           (SELECT min(st.day) FROM st WHERE st.day >= v_today AND st.bal < st.thr),
           (SELECT min(st.bal - st.thr) FROM st WHERE st.day >= v_today),
           (SELECT st.day FROM st WHERE st.day >= v_today ORDER BY st.bal - st.thr, st.day LIMIT 1),
           COALESCE((SELECT bool_or(st.fx_gap) FROM st), false)
    INTO v_bal, v_min, v_min_date, v_out_on, v_min_free, v_free_date, v_gap;
    v_bal := COALESCE(v_bal, finance.fn_get_balance_as_of(p_account_id, v_today), 0);
    v_gap := v_gap OR v_fgap;

    v_state := CASE WHEN v_gap OR v_everyday = 'unknown' THEN 'neutral'
                    WHEN v_out_on <= (v_today + make_interval(months => v_alert))::date THEN 'alert'
                    WHEN v_out_on IS NOT NULL THEN 'warn'
                    ELSE 'ok' END;

    RETURN jsonb_build_object('ok', true,
        'account_id', p_account_id, 'currency', v_acct.currency,
        'balance', round(v_bal, 2), 'monthly_in', v_in, 'monthly_out', v_out,
        'everyday', v_everyday, 'everyday_per_day', v_per_day,
        'min_projected', round(v_min, 2), 'min_date', v_min_date, 'runs_out_on', v_out_on, 'horizon_end', v_until,
        'state', v_state, 'fx_gap', v_gap, 'reserved', round(v_res, 2), 'min_free', round(v_min_free, 2), 'min_free_date', v_free_date);
END;
$$;
