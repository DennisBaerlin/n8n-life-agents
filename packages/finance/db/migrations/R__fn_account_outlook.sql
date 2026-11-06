-- ============================================================
-- fn_account_outlook (READ, STABLE, RAISE-frei) -- Deckungs-Vorschau eines Kontos (Monats-Check WP-E)
--   "Reicht das Geld bis zum naechsten Geldeingang?" — die EINE Rechen-Adresse fuer die Antwort nach dem Monats-Check
--   (fn_apply_bank_statement), die Berater-Warnung account_coverage (fn_advisor_review) und die Bruecke des
--   Mini-App-Bildschirms „Konten“. Muster Quicken Simplifi "projected balance + low-balance alert"; die DB rechnet,
--   das LLM formuliert nur.
--   Modell (Einzelumsaetze werden nicht gespeichert -> Alltagsausgaben sind eine Schaetzung):
--     d0 = Tag nach dem bestaetigten Stand (last_reconciled_at, sonst heute).
--     Stand(d) = Tagesreihe des EINEN Rechenkerns finance.fn_account_projection(konto, d0, Horizont, Alltag je Tag)
--     (Basis = Saldo zum Vortag von d0 + Buchungen + offene Dauerauftrags-Vorkommen; Transfer-Ziel in Zielwaehrung);
--     derselbe Kern rechnet die Spar-Deckung fn_account_funding. Alltagsausgaben je Tag =
--     finance.fn_account_everyday_per_day (gezaehlte Auszuege, 0 ohne Historie; provisional = nur ein Auszug).
--     Horizont = naechstes Vorkommen der groessten Einnahme AUF DIESES Konto (Einnahme oder Transfer-Ziel) nach heute,
--     sonst heute + 31. Tiefster Stand ueber [heute, Horizont].
--   Puffer = accounts.min_balance (Kontowaehrung, buffer_source 'account'), sonst core.config
--   finance.coverage_buffer_eur (Default 250) in die Kontowaehrung umgerechnet (buffer_source 'default').
--   Bruecke (Transparenz 2026-10-30) = Teilsummen derselben Reihe von d0 bis min_date: base (Saldo zum Vortag von d0;
--   weicht er vom bestaetigten Stand ab, steht eine rueckdatierte Buchung dazwischen) + booked + out + in + everyday
--   = min_projected exakt. confirmed = bestaetigter Stand (NULL ohne Abgleich).
--   Vorschlag bei Unterschreitung: Umbuchung (auf 50 aufgerundet) bis 2 Tage vor dem Tief von dem cash-Konto gleicher
--   Waehrung mit dem groessten freien Saldo (account_reserve_status: Saldo - Ruecklage), wenn es den Betrag hat; nie von
--   einem Kinderkonto (Eigentuemer role child, core.fn_household_persons): der Vorschlag geht ohne LLM in Karte/Alert.
--   RUECKGABE: {ok, account_id, account_name, currency, confirmed_balance, confirmed_as_of, estimated_today,
--   next_income_date, next_income_name, next_income_amount, next_income_rp_id, horizon_end, planned_out, planned_in, everyday_per_day,
--   has_history, provisional, min_projected, min_date, buffer, buffer_source, shortfall,
--   bridge:{from, base, confirmed, booked, out, in, everyday, days},
--   suggestion:{amount, by_date, from_account} | null} | {ok:false}
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
    v_prov     BOOLEAN;
    v_inc_name TEXT;
    v_inc_amt  NUMERIC;
    v_inc_rp   INT;
    v_horizon  DATE;
    v_inc_date DATE;
    v_min      NUMERIC;
    v_min_date DATE;
    v_est      NUMERIC;
    v_out      NUMERIC;
    v_in       NUMERIC;
    v_buffer   NUMERIC;
    v_bsrc     TEXT;
    v_short    NUMERIC;
    v_sugg     JSONB;
    v_bridge   JSONB;
BEGIN
    SELECT * INTO v_acct FROM finance.accounts WHERE id = p_account_id;
    IF NOT FOUND OR v_acct.account_type <> 'cash' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Outlook is only available for cash accounts.');
    END IF;
    v_d0   := COALESCE(v_acct.last_reconciled_at + 1, v_today);
    v_base := COALESCE(finance.fn_get_balance_as_of(p_account_id, v_d0 - 1), 0);

    SELECT e.per_day, e.has_history, e.provisional INTO v_per_day, v_hist, v_prov
    FROM finance.fn_account_everyday_per_day(p_account_id) e;

    -- groesste Einnahme auf dieses Konto (Einnahme-rp oder Transfer-Ziel), naechstes offenes Vorkommen nach heute.
    -- Quelle = fn_recurring_due_open (kennt Status/Gueltigkeit; ein erst kuenftig startendes Gehalt zaehlt mit).
    SELECT o.due_date, r.name, r.id INTO v_inc_date, v_inc_name, v_inc_rp
    FROM finance.fn_recurring_due_open(v_today + 1, v_today + 400) o
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id
    WHERE (r.account_id = p_account_id AND r.amount > 0 AND r.target_account_id IS NULL) OR r.target_account_id = p_account_id
    ORDER BY abs(r.monthly_equivalent) DESC, o.due_date, r.id LIMIT 1;
    v_horizon := COALESCE(v_inc_date, v_today + 31);

    WITH s AS (
        SELECT * FROM finance.fn_account_projection(p_account_id, v_d0, v_horizon, v_per_day)
    )
    SELECT (SELECT s.bal FROM s WHERE s.day = GREATEST(v_today, v_d0)),
           (SELECT s.bal FROM s WHERE s.day >= v_today ORDER BY s.bal, s.day LIMIT 1),
           (SELECT s.day FROM s WHERE s.day >= v_today ORDER BY s.bal, s.day LIMIT 1),
           (SELECT COALESCE(sum(s.outflow), 0) FROM s),
           (SELECT COALESCE(sum(s.inflow), 0) FROM s)
    INTO v_est, v_min, v_min_date, v_out, v_in;

    -- Bruecke bis zum Tief: dieselbe Reihe, Teilsummen d0..min_date (Alltag = per_day x Tage, wie im Kern); ohne Tief
    -- (leere Reihe) keine Bruecke
    IF v_min_date IS NOT NULL THEN
    WITH s AS (
        SELECT * FROM finance.fn_account_projection(p_account_id, v_d0, v_min_date, v_per_day)
    )
    SELECT jsonb_build_object(
               'from', v_d0, 'base', round(v_base, 2), 'confirmed', v_acct.last_reconciled_balance,
               'booked', round(COALESCE(sum(s.booked), 0), 2),
               'out', round(COALESCE(sum(s.planned_out), 0), 2),
               'in', round(COALESCE(sum(s.planned_in), 0), 2),
               'everyday', round(COALESCE(v_per_day, 0) * count(*), 2),
               'days', count(*))
    INTO v_bridge
    FROM s;
    END IF;

    -- Betrag des naechsten Geldeingangs (dieselbe Quelle wie die Reihe: Zielwaehrung, Kredit-Schlussrate)
    SELECT sum(pf.amount) INTO v_inc_amt
    FROM finance.fn_account_planned_flows(p_account_id, v_inc_date, v_inc_date) pf
    WHERE v_inc_date IS NOT NULL AND pf.recurring_payment_id = v_inc_rp;

    IF v_acct.min_balance IS NOT NULL THEN
        v_buffer := v_acct.min_balance;
        v_bsrc   := 'account';
    ELSE
        v_bsrc   := 'default';
        -- Kontowaehrung zum heutigen Kurs (fn_config_eur_in_currency); ohne Kurs der EUR-Wert (bisherige Rueckfallebene)
        v_buffer := COALESCE(finance.fn_config_eur_in_currency('coverage_buffer_eur', 250, v_acct.currency, CURRENT_DATE),
                             finance.fn_config_eur_in_currency('coverage_buffer_eur', 250, 'EUR', CURRENT_DATE));
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
          AND NOT EXISTS (SELECT 1 FROM core.fn_household_persons() hp
                          WHERE hp.person_id = a.owner_person_id AND hp.role = 'child')
          AND s.balance - GREATEST(s.reserved, 0) >= ceil(v_short / 50) * 50
        ORDER BY s.balance - GREATEST(s.reserved, 0) DESC, s.account_id LIMIT 1;
    END IF;

    RETURN jsonb_build_object('ok', true,
        'account_id', p_account_id, 'account_name', v_acct.name, 'currency', v_acct.currency,
        'confirmed_balance', v_acct.last_reconciled_balance, 'confirmed_as_of', v_acct.last_reconciled_at,
        'estimated_today', round(v_est, 2),
        'next_income_date', v_inc_date, 'next_income_name', v_inc_name, 'next_income_amount', v_inc_amt,
        'next_income_rp_id', v_inc_rp,
        'horizon_end', v_horizon,
        'planned_out', round(v_out, 2), 'planned_in', round(v_in, 2),
        'everyday_per_day', v_per_day, 'has_history', COALESCE(v_hist, false), 'provisional', COALESCE(v_prov, false),
        'min_projected', round(v_min, 2), 'min_date', v_min_date,
        'buffer', v_buffer, 'buffer_source', v_bsrc, 'shortfall', v_short,
        'bridge', v_bridge, 'suggestion', v_sugg);
END;
$$;
