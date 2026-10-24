-- ============================================================
-- fn_interest_rate_preview (READ) -- die wirksamen Werte einer neuen Zinszeile, BEVOR sie geschrieben wird
--   EINE Quelle fuer die HITL-Karte von tool_set_account_interest UND fn_set_account_interest (Karte = Buchung,
--   Audit Paket 2 Review). Regeln (Audit Paket 2, Punkt 5 -- vorher Default 'year' bei reinem Satzwechsel ->
--   Doppelverzinsung):
--     unit     = Eingabe > offene Zeile (KEIN 'year'-Rueckfall mehr, Live-Befund 2026-10-24)
--     interval = Eingabe > offene Zeile (nur bei unveraenderter unit) > 1
--     dom / posting_day_of_month = Eingabe > offene Zeile (nur bei unveraenderter unit)
--     Beginnt ein neues Raster (keine offene Zeile oder anderer Rhythmus/Intervall/Tag), gilt die Pflicht-Kadenz
--       fn_interest_schedule_reason auf den wirksamen Werten -> {ok:false, code:'missing_required', reason}.
--     first_period_end / first_credit_date = die erste Gutschrift ab valid_from (fn_interest_next_period_end auf dem
--       Raster des laufenden Regimes bzw. dem neuen ab valid_from; Karte "Erste Gutschrift").
--     auto_post = Eingabe > offene Zeile (nur bei unveraenderter Kadenz) > fn_interest_auto_post_default(unit)
--     day_count_convention = Eingabe > offene Zeile > fn_interest_default_convention(Kontotyp); conv_reason =
--       manual | previous | default_cash | default_fixed | default
--     valid_from = Eingabe > heute
--   KORRIGIERBAR -> {ok:false, reason}: ungueltiger Abbuchungstag; Kontotyp nicht zins-faehig; Satz fehlt/negativ;
--   valid_from nicht nach der offenen Zeile; valid_from VOR dem Ende der juengsten gebuchten/uebersprungenen
--   Zinsperiode (Review: ein rueckdatierter Kadenzwechsel verankerte ein Raster ueber schon verzinste Tage).
--   Eingabe jsonb wie fn_set_account_interest. RUECKGABE {ok:true, schedule_interval, schedule_unit,
--   schedule_day_of_month, posting_day_of_month, auto_post, day_count_convention, conv_reason, valid_from,
--   closes_previous, first_period_end, first_credit_date}. RAISE nur bei unbekanntem Konto.
--   Tests: tests/db/finance/test_fn_set_account_interest.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_rate_preview(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_acct      INT      := (p->>'account_id')::int;
    v_rate      NUMERIC  := NULLIF(p->>'annual_rate', '')::numeric;
    v_interval  SMALLINT := NULLIF(p->>'schedule_interval', '')::smallint;
    v_unit      finance.schedule_unit;   -- Cast erst nach dem Guard (Import-Haertung)
    v_dom       SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_pdom      SMALLINT := NULLIF(p->>'posting_day_of_month', '')::smallint;
    v_from      DATE     := COALESCE(NULLIF(p->>'valid_from', '')::date, CURRENT_DATE);
    v_acct_type finance.account_type;
    v_open      finance.account_interest_rates%ROWTYPE;
    v_same      BOOLEAN;
    v_last_done DATE;
    v_conv      TEXT;
    v_reason    TEXT;
    v_regime_same BOOLEAN;
    v_anchor    DATE;
    v_first_pe  DATE;
BEGIN
    -- Rhythmus, Buchungs-/Gutschrift-Tag, Konvention: EIN Guard mit fn_create_account (fn_interest_terms_reason).
    v_reason := finance.fn_interest_terms_reason(p->>'schedule_unit', v_dom, v_pdom, p->>'day_count_convention');
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_unit := NULLIF(p->>'schedule_unit', '')::finance.schedule_unit;
    SELECT account_type INTO v_acct_type FROM finance.accounts WHERE id = v_acct;
    IF v_acct_type IS NULL THEN
        RAISE EXCEPTION 'Account % not found.', v_acct;
    END IF;
    IF NOT finance.fn_interest_eligible_account_type(v_acct_type) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Interest applies only to cash, fixed-deposit and P2P accounts (account type ' || v_acct_type || ' is not eligible).');
    END IF;
    IF v_rate IS NULL OR v_rate < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Annual rate must be a non-negative number, got ' || COALESCE(v_rate::text, 'null') || '.');
    END IF;
    v_reason := finance.fn_rate_precision_reason(v_rate, 'Annual rate');   -- numeric(6,4) kuerzte still (Rundungs-Paket)
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    SELECT * INTO v_open
    FROM finance.account_interest_rates
    WHERE account_id = v_acct AND valid_to IS NULL
    ORDER BY valid_from DESC
    LIMIT 1;

    IF v_open.id IS NOT NULL AND v_from <= v_open.valid_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'New valid_from (' || v_from || ') must be after the current rate valid_from (' || v_open.valid_from || ').',
            'current_valid_from', v_open.valid_from);
    END IF;

    v_last_done := finance.fn_interest_last_done(v_acct);
    IF v_last_done IS NOT NULL AND v_from < v_last_done THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Interest is already credited (or skipped) up to ' || v_last_done || '. A new rate can start on '
                   || v_last_done || ' at the earliest.',
            'credited_until', v_last_done);
    END IF;

    v_unit     := COALESCE(v_unit, v_open.schedule_unit);   -- kein erfundenes 'year' (Live-Befund 2026-10-24)
    v_interval := COALESCE(v_interval, CASE WHEN v_unit = v_open.schedule_unit THEN v_open.schedule_interval END, 1);
    v_same     := v_open.id IS NOT NULL AND v_unit = v_open.schedule_unit AND v_interval = v_open.schedule_interval;
    -- Tag/Arrears nur bei GLEICHER Einheit erben: ein Wechsel month/-1 -> year truege sonst still "31.12." statt
    -- Jahrestag mit (seit dem Kalender-Raster wirkt dom auch bei year).
    v_dom      := COALESCE(v_dom, CASE WHEN v_unit = v_open.schedule_unit THEN v_open.schedule_day_of_month END);
    v_pdom     := COALESCE(v_pdom, CASE WHEN v_unit = v_open.schedule_unit THEN v_open.posting_day_of_month END);
    -- Pflicht-Kadenz auf den WIRKSAMEN Werten, sobald ein neues Raster beginnt (keine offene Zeile oder anderer
    -- Rhythmus/Intervall/Tag). Ein reiner Satzwechsel auf einer Altzeile (z. B. month ohne Tag) bleibt erlaubt.
    v_regime_same := v_same AND v_dom IS NOT DISTINCT FROM v_open.schedule_day_of_month;
    IF NOT v_regime_same THEN
        v_reason := finance.fn_interest_schedule_reason(v_unit, v_interval, v_dom, 'rate');
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'missing_required', 'reason', v_reason);
        END IF;
    END IF;
    -- Erste Gutschrift (Karte): gleiches Raster -> naechster Rasterpunkt des laufenden Regimes nach valid_from; neues
    -- Raster -> ab valid_from (das alte Regime endet dort ohne eigene Gutschrift, sein Rest laeuft in die erste neue Periode).
    IF v_regime_same THEN
        SELECT r.anchor INTO v_anchor FROM finance.fn_interest_regimes(v_acct) r ORDER BY r.regime_start DESC LIMIT 1;
    END IF;
    v_first_pe := finance.fn_interest_next_period_end(COALESCE(v_anchor, v_from), v_from, v_interval, v_unit, v_dom);

    v_conv := COALESCE(NULLIF(p->>'day_count_convention', ''), v_open.day_count_convention,
                       finance.fn_interest_default_convention(v_acct_type));
    v_reason := CASE
        WHEN NULLIF(p->>'day_count_convention', '') IS NOT NULL THEN 'manual'
        WHEN v_open.day_count_convention IS NOT NULL THEN 'previous'
        WHEN v_acct_type = 'cash' THEN 'default_cash'
        WHEN v_acct_type = 'fixed_deposit' THEN 'default_fixed'
        ELSE 'default' END;

    RETURN jsonb_build_object('ok', true,
        'schedule_interval',     v_interval,
        'schedule_unit',         v_unit,
        'schedule_day_of_month', v_dom,
        'posting_day_of_month',  v_pdom,
        'auto_post',             COALESCE(NULLIF(p->>'auto_post', '')::boolean,
                                          CASE WHEN v_same THEN v_open.auto_post END,
                                          finance.fn_interest_auto_post_default(v_unit)),
        'day_count_convention',  v_conv,
        'conv_reason',           v_reason,
        'valid_from',            v_from,
        'closes_previous',       v_open.id IS NOT NULL,
        'first_period_end',      v_first_pe,
        'first_credit_date',     finance.fn_interest_value_date(v_first_pe, v_pdom));
END;
$$;
