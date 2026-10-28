-- ============================================================
-- fn_account_outlook (READ, STABLE, RAISE-frei) -- Deckungs-Vorschau eines Kontos (Monats-Check WP-E)
--   "Reicht das Geld bis zum naechsten Geldeingang?" — die EINE Rechen-Adresse fuer die Antwort nach dem Monats-Check
--   (fn_apply_bank_statement) und die Berater-Warnung account_coverage (fn_advisor_review). Muster Quicken Simplifi
--   "projected balance + low-balance alert"; die DB rechnet, das LLM formuliert nur.
--   Modell (Einzelumsaetze werden nicht gespeichert -> Alltagsausgaben sind eine Schaetzung):
--     d0 = Tag nach dem bestaetigten Stand (last_reconciled_at, sonst heute); Basis = Saldo zum Vortag von d0.
--     Stand(d) = Basis + Buchungen in [d0, d] + offene Dauerauftrags-Vorkommen in [d0, d] (finance.fn_upcoming_payments:
--     Quelle -, Transfer-Ziel +, Kredit-Schlussrate = Abloese) + Alltagsausgaben je Tag x Tage.
--     Alltagsausgaben je Tag = Summe unmatched_out / Summe neu abgeglichener Tage (period_end - damaliger Schnitt) der
--     letzten 3 Auszuege (0 ohne Historie).
--     Horizont = naechstes Vorkommen der groessten Einnahme AUF DIESES Konto (Einnahme oder Transfer-Ziel) nach heute,
--     sonst heute + 31. Tiefster Stand ueber [heute, Horizont].
--   Puffer = core.config finance.coverage_buffer_eur (Default 250), in die Kontowaehrung umgerechnet.
--   Vorschlag bei Unterschreitung: Umbuchung (auf 50 aufgerundet) bis 2 Tage vor dem Tief von dem cash-Konto gleicher
--   Waehrung mit dem groessten freien Saldo (account_reserve_status: Saldo - Ruecklage), wenn es den Betrag hat.
--   RUECKGABE: {ok, account_id, account_name, currency, confirmed_balance, confirmed_as_of, estimated_today,
--   next_income_date, next_income_name, horizon_end, planned_out, planned_in, everyday_per_day, has_history,
--   min_projected, min_date, buffer, shortfall, suggestion:{amount, by_date, from_account} | null} | {ok:false}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_outlook(p_account_id int)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_acct     finance.accounts%ROWTYPE;
    v_today    DATE := CURRENT_DATE;
    v_d0       DATE;
    v_base     NUMERIC;
    v_per_day  NUMERIC := 0;
    v_hist     BOOLEAN;
    v_inc_name TEXT;
    v_horizon  DATE;
    v_inc_date DATE;
    v_min      NUMERIC;
    v_min_date DATE;
    v_est      NUMERIC;
    v_out      NUMERIC;
    v_in       NUMERIC;
    v_buffer   NUMERIC;
    v_eur1     NUMERIC;
    v_short    NUMERIC;
    v_sugg     JSONB;
BEGIN
    SELECT * INTO v_acct FROM finance.accounts WHERE id = p_account_id;
    IF NOT FOUND OR v_acct.account_type <> 'cash' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Outlook is only available for cash accounts.');
    END IF;
    v_d0   := COALESCE(v_acct.last_reconciled_at + 1, v_today);
    v_base := COALESCE(finance.fn_get_balance_as_of(p_account_id, v_d0 - 1), 0);

    -- Nenner = die Tage NACH dem damaligen Schnitt (unmatched_out zaehlt nur Zeilen danach; ueberlappende Auszuege
    -- wuerden mit der vollen Zeitraumlaenge zu niedrig geschaetzt). Schnitt wie fn_statement_prepare.
    SELECT sum(b.unmatched_out)
           / NULLIF(sum(b.period_end - GREATEST(b.period_start - 1, b.prev_last_reconciled_at, v_acct.opening_balance_date)), 0),
           count(*) > 0
    INTO v_per_day, v_hist
    FROM (SELECT * FROM finance.bank_statements WHERE account_id = p_account_id ORDER BY period_end DESC LIMIT 3) b;
    v_per_day := round(COALESCE(v_per_day, 0), 2);

    -- groesste Einnahme auf dieses Konto (Einnahme-rp oder Transfer-Ziel), naechstes offenes Vorkommen nach heute.
    -- Quelle = fn_recurring_due_open (kennt Status/Gueltigkeit; ein erst kuenftig startendes Gehalt zaehlt mit).
    SELECT o.due_date, r.name INTO v_inc_date, v_inc_name
    FROM finance.fn_recurring_due_open(v_today + 1, v_today + 400) o
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id
    WHERE (r.account_id = p_account_id AND r.amount > 0 AND r.target_account_id IS NULL) OR r.target_account_id = p_account_id
    ORDER BY abs(r.monthly_equivalent) DESC, o.due_date, r.id LIMIT 1;
    v_horizon := COALESCE(v_inc_date, v_today + 31);

    WITH days AS (
        SELECT gs::date AS d FROM generate_series(v_d0, v_horizon, interval '1 day') gs
    ), flows AS (
        -- Dauerauftraege aus der einen Quelle finance.fn_upcoming_payments: Quell-Seite = Buchungsbetrag (Kredit-
        -- Schlussrate = Abloese), Ziel-Seite eines Uebertrags = abs(geplanter Betrag)
        SELECT u.due_date AS d,
               CASE WHEN u.account_id = p_account_id THEN u.amount ELSE abs(u.planned_amount) END AS amt
        FROM finance.fn_upcoming_payments(v_d0, v_horizon) u
        WHERE u.account_id = p_account_id OR u.target_account_id = p_account_id
        UNION ALL
        SELECT t.transaction_date, t.amount FROM finance.transactions t
        WHERE t.account_id = p_account_id AND t.transaction_date BETWEEN v_d0 AND v_horizon
    ), series AS (
        SELECT dd.d,
               v_base + COALESCE((SELECT sum(f.amt) FROM flows f WHERE f.d <= dd.d), 0)
                      + v_per_day * (dd.d - v_d0 + 1) AS bal
        FROM days dd
    )
    SELECT (SELECT bal FROM series WHERE d = GREATEST(v_today, v_d0)),
           (SELECT bal FROM series WHERE d >= v_today ORDER BY bal, d LIMIT 1),
           (SELECT d   FROM series WHERE d >= v_today ORDER BY bal, d LIMIT 1),
           (SELECT COALESCE(sum(amt), 0) FROM flows WHERE amt < 0),
           (SELECT COALESCE(sum(amt), 0) FROM flows WHERE amt > 0)
    INTO v_est, v_min, v_min_date, v_out, v_in;

    v_buffer := COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'coverage_buffer_eur'), '')::numeric, 250);
    IF v_acct.currency <> 'EUR' THEN
        -- ungerundet: 1 KRW = 0.00069 EUR wurde mit Cent-Rundung 0.00 (Puffer still wirkungslos), 1 JPY 0.01 (37 % daneben)
        v_eur1 := finance.fn_to_eur_unrounded(1, v_acct.currency);
        v_buffer := CASE WHEN v_eur1 > 0 THEN round(v_buffer / v_eur1, 2) ELSE v_buffer END;
    END IF;
    v_short := GREATEST(v_buffer - round(COALESCE(v_min, v_base), 2), 0);

    IF v_short > 0 THEN
        SELECT jsonb_build_object('amount', ceil(v_short / 50) * 50, 'by_date', GREATEST(v_min_date - 2, v_today),
                                  'from_account', s.account_name)
        INTO v_sugg
        FROM finance.account_reserve_status s
        JOIN finance.accounts a ON a.id = s.account_id
        WHERE s.account_id <> p_account_id AND a.account_type = 'cash' AND a.status = 'active'
          AND a.currency = v_acct.currency
          AND s.balance - GREATEST(s.reserved, 0) >= ceil(v_short / 50) * 50
        ORDER BY s.balance - GREATEST(s.reserved, 0) DESC, s.account_id LIMIT 1;
    END IF;

    RETURN jsonb_build_object('ok', true,
        'account_id', p_account_id, 'account_name', v_acct.name, 'currency', v_acct.currency,
        'confirmed_balance', v_acct.last_reconciled_balance, 'confirmed_as_of', v_acct.last_reconciled_at,
        'estimated_today', round(v_est, 2),
        'next_income_date', v_inc_date, 'next_income_name', v_inc_name, 'horizon_end', v_horizon,
        'planned_out', round(v_out, 2), 'planned_in', round(v_in, 2),
        'everyday_per_day', v_per_day, 'has_history', COALESCE(v_hist, false),
        'min_projected', round(v_min, 2), 'min_date', v_min_date,
        'buffer', v_buffer, 'shortfall', v_short, 'suggestion', v_sugg);
END;
$$;
