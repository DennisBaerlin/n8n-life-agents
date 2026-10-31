-- ============================================================
-- fn_account_low_state (READ, STABLE, RAISE-frei) -- das EINE Urteil „Tiefster Stand“ eines Geld-Kontos
--   UX-Gesamtkonzept 2026-10-31 (5.2, P12): dieselbe Antwort fuer die Konten-Zeile „Tiefster Stand“, den Konten-Banner
--   der Startseite und die Spiegel-Pille am Sparplan (Ziele) — beide Tabs koennen sich so nicht widersprechen.
--   Quelle:
--     outlook  Konto mit Kontoauszug (finance.fn_coverage_accounts, cash): finance.fn_account_outlook bis zum naechsten
--              Geldeingang mit Puffer; Zustand wie die Berater-Warnung (Kurs fehlt -> neutral, shortfall > 0 -> alert,
--              tiefster Stand < finance.coverage_warn_factor x Puffer -> warn). Ist das Konto zugleich Deckungs-Konto
--              (finance.fn_funding_accounts), rechnet zusaetzlich finance.fn_account_funding (Ziel-Geld, 24 Monate) und
--              das SCHLECHTERE Urteil gilt (verdict sagt welches: 'buffer' oder 'goals').
--     funding  sonst Deckungs-Konto mit bekannten Alltagsausgaben (everyday <> 'unknown': Sparkonto, Broker-Cash,
--              Taschengeldkonto, P2P mit Lastschrift): finance.fn_account_funding, Wert = tiefster FREIER Stand.
--     none     alles andere (Alltagskonto ohne Auszug, Topf/Festgeld ohne Abfluesse): kein Urteil (state neutral).
--   has_outflow = im Horizont geht etwas ab (Zahlung oder geschaetzter Alltag); sonst zeigt die App keine Zeile
--   (sie waere = „Stand heute“). gap = Kurs der Kontowaehrung fehlt (Zeile markiert, keine Pille).
--   p_alert_only = true (probe beim App-Start): fn_account_funding rechnet nur das alert-Fenster.
--   Liefert keine Namen (next_income_name, Vorschlag): die Sichtbarkeit je Person bleibt im Handler.
--   RUECKGABE: {ok, account_id, currency, source, state, verdict, amount, low_date, on_date, month, buffer,
--   has_outflow, gap, monthly_in, monthly_out, short_by} | {ok:false} (unbekannt, Kredit-/Depotkonto)
--   on_date = Datum zum Urteil (buffer: Tag des Tiefs, goals: erster Tag unter dem Ziel-Geld), month = dessen Monat.
--   short_by = so viel fehlt bis zum Puffer (fn_account_outlook.shortfall, >= 0) bei verdict buffer, sonst null: die
--   Pille „{amount} unter dem Puffer" lesen Konten-Zeile und Spiegel-Pille am Sparplan (Ziele) nur hier, keiner rechnet nach.
--   Tests: tests/db/finance/test_fn_account_low_state.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_low_state(p_account_id int, p_alert_only boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_acct    finance.accounts%ROWTYPE;
    v_factor  numeric;
    v_o       jsonb;
    v_f       jsonb;
    v_src     text := 'none';
    v_state   text := 'neutral';
    v_verdict text;
    v_amount  numeric;
    v_low     date;
    v_on      date;
    v_buffer  numeric;
    v_out     boolean := false;
    v_gap     boolean := false;
    v_in_m    numeric;
    v_out_m   numeric;
BEGIN
    SELECT * INTO v_acct FROM finance.accounts WHERE id = p_account_id;
    IF NOT FOUND OR v_acct.account_type::text IN ('loan', 'stocks_depot', 'crypto_depot') THEN
        RETURN jsonb_build_object('ok', false);
    END IF;
    v_factor := COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'coverage_warn_factor'), '')::numeric, 2);

    IF EXISTS (SELECT 1 FROM finance.fn_coverage_accounts() c(id) WHERE c.id = p_account_id) THEN
        v_o := finance.fn_account_outlook(p_account_id);
    END IF;
    IF (v_o->>'ok') = 'true' THEN
        v_src    := 'outlook';
        v_verdict := 'buffer';
        v_gap    := v_acct.currency <> 'EUR' AND finance.fn_to_eur_unrounded(1, v_acct.currency) IS NULL;
        v_amount := (v_o->>'min_projected')::numeric;
        v_low    := (v_o->>'min_date')::date;
        v_on     := v_low;
        v_buffer := (v_o->>'buffer')::numeric;
        v_out    := COALESCE((v_o->>'planned_out')::numeric, 0) < 0 OR COALESCE((v_o->>'everyday_per_day')::numeric, 0) < 0;
        v_state  := CASE WHEN v_gap THEN 'neutral'
                         WHEN (v_o->>'shortfall')::numeric > 0 THEN 'alert'
                         WHEN v_amount < v_factor * v_buffer THEN 'warn'
                         ELSE 'ok' END;
        IF NOT v_gap AND EXISTS (SELECT 1 FROM finance.fn_funding_accounts() fa WHERE fa.account_id = p_account_id) THEN
            v_f := finance.fn_account_funding(p_account_id, p_alert_only);
            IF (v_f->>'ok') = 'true'
               AND array_position(ARRAY['ok', 'warn', 'alert'], v_f->>'state') > COALESCE(array_position(ARRAY['ok', 'warn', 'alert'], v_state), 0) THEN
                v_state   := v_f->>'state';
                v_verdict := 'goals';
                v_on      := (v_f->>'runs_out_on')::date;
            END IF;
        END IF;
    ELSIF EXISTS (SELECT 1 FROM finance.fn_funding_accounts() fa WHERE fa.account_id = p_account_id) THEN
        v_f := finance.fn_account_funding(p_account_id, p_alert_only);
        IF (v_f->>'ok') = 'true' AND v_f->>'everyday' <> 'unknown' THEN
            v_src     := 'funding';
            v_verdict := 'goals';
            v_gap     := COALESCE((v_f->>'fx_gap')::boolean, false);
            v_state   := CASE WHEN v_gap THEN 'neutral' ELSE v_f->>'state' END;
            v_amount  := (v_f->>'min_free')::numeric;
            v_low     := COALESCE((v_f->>'min_free_date')::date, (v_f->>'min_date')::date);
            v_on      := (v_f->>'runs_out_on')::date;
            v_in_m    := (v_f->>'monthly_in')::numeric;
            v_out_m   := (v_f->>'monthly_out')::numeric;
            v_out     := COALESCE(v_out_m, 0) < 0 OR COALESCE((v_f->>'everyday_per_day')::numeric, 0) < 0;
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'account_id', p_account_id, 'currency', v_acct.currency,
        'source', v_src, 'state', v_state, 'verdict', v_verdict,
        'amount', round(v_amount, 2), 'low_date', v_low, 'on_date', v_on,
        'month', to_char(v_on, 'YYYY-MM'), 'buffer', round(v_buffer, 2),
        'has_outflow', v_out, 'gap', v_gap, 'monthly_in', v_in_m, 'monthly_out', v_out_m,
        'short_by', CASE WHEN v_verdict = 'buffer' THEN (v_o->>'shortfall')::numeric END);
END;
$$;
