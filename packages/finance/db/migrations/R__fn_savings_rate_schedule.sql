-- ============================================================
-- fn_savings_rate_schedule (READ-ONLY HELPER, STABLE)
--   Berechnet die fehlende Groesse eines Sparplans DETERMINISTISCH -- damit das LLM
--   NICHT rechnet (Root-CLAUDE.md *Das LLM rechnet NICHT*). Zwei Richtungen:
--     - Ziel-getrieben: target_amount + target_date gegeben -> monthly_rate = Ziel / Monate.
--     - Raten-getrieben: target_amount + monthly_savings_rate gegeben -> target_date = first + ceil(Ziel/Rate) Monate.
--   Die Rate wird auf den Cent AUFGERUNDET (Audit Paket 2, Punkt 15): 1000 / 3 = 333.34, damit die Raten das Ziel
--   erreichen (gerundet 333.33 -> 999.99, "erreicht" feuerte nie). Sparziele sind EUR -> Cent.
--   Anker der Monatszaehlung ist first_payment_date. Wird VOM TOOL read-only fuer den HITL-Preview
--   UND von fn_create_savings_goal (autoritativ, im Write) aufgerufen -> eine Quelle, kein Drift.
--   ERSTE RATE (WP2 "Finanzen schlank", weniger Rueckfragen): first_payment_date leer = der naechste Termin des
--   Abbuchungstags ab heute (schedule_day_of_month; ohne Tag: heute) -- dasselbe Raster wie der Scheduler
--   (fn_schedule_occurrences). Deshalb STABLE (heute), nicht mehr IMMUTABLE.
--   REST STATT GESAMT (Sparziel-Zweckbindung 2026-10-27): already_saved (opt, EUR, z. B. ein Startbestand, der schon
--   auf dem Topf liegt) wird vom Ziel abgezogen; gerechnet wird auf dem Rest. Rest <= 0 -> das Ziel ist gedeckt:
--   {ok:true, monthly_rate:0, months:0}; dann ist target_date Pflicht und muss in der Zukunft liegen (ein Ziel ohne
--   Datum gibt es nicht, eine Rate gibt es nicht mehr abzuleiten).
--   Eingabe jsonb: target_amount, already_saved (opt), first_payment_date (opt), schedule_day_of_month (opt), plus GENAU
--   EINES von {target_date, monthly_savings_rate}.
--   Rueckgabe: {ok:true, monthly_rate, target_date, months, first_payment_date (wirksam)} ODER {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_rate_schedule(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_target NUMERIC := NULLIF(p->>'target_amount', '')::numeric;
    v_saved  NUMERIC := COALESCE(NULLIF(p->>'already_saved', '')::numeric, 0);
    v_rest   NUMERIC;
    v_date   DATE;
    v_rate   NUMERIC := NULLIF(p->>'monthly_savings_rate', '')::numeric;
    v_first  DATE;
    v_months INT;
    v_dates  JSONB;
BEGIN
    -- relative Datumsangaben ("in 2 years") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}. Die Karte
    -- (tool_create_savings_goal) liest die Termine aus dieser fn, fn_create_savings_goal ebenfalls -> Karte = Write.
    v_dates := core.fn_resolve_input_dates(p, ARRAY['target_date', 'first_payment_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date  := NULLIF(p->>'target_date', '')::date;
    v_first := NULLIF(p->>'first_payment_date', '')::date;
    IF v_target IS NULL OR v_target <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Target amount must be a positive number, got ' || COALESCE(v_target::text, 'null') || '.');
    END IF;
    IF v_first IS NULL THEN
        SELECT min(d) INTO v_first
        FROM finance.fn_schedule_occurrences(core.fn_today(), 1, 'month', NULLIF(p->>'schedule_day_of_month', '')::smallint,
                                             NULL, core.fn_today(), core.fn_today() + 62) d;
    END IF;
    v_rest := v_target - v_saved;

    -- Gedeckt: keine Rate mehr ableitbar -> Rate 0; das Zieldatum ist Pflicht und muss in der Zukunft liegen.
    IF v_rest <= 0 THEN
        IF v_date IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The goal is already covered by the money that is already saved, so no monthly rate is needed - '
                       || 'ask the user for the target date (when the money will be used).');
        END IF;
        IF v_date <= core.fn_today() THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Target date (' || v_date || ') must be in the future.');
        END IF;
        RETURN jsonb_build_object('ok', true, 'monthly_rate', 0, 'target_date', v_date, 'months', 0,
            'first_payment_date', v_first);
    END IF;

    IF v_date IS NOT NULL THEN
        -- Ziel-getrieben: Rate aus Rest / Monate (Monatsgranularitaet, Anker first_payment_date).
        IF v_date <= v_first THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Target date must be after the first payment date (' || v_first || ').');
        END IF;
        v_months := ( (EXTRACT(YEAR FROM v_date)::int * 12 + EXTRACT(MONTH FROM v_date)::int)
                    - (EXTRACT(YEAR FROM v_first)::int * 12 + EXTRACT(MONTH FROM v_first)::int) );
        v_months := GREATEST(v_months, 1);
        RETURN jsonb_build_object('ok', true,
            'monthly_rate', CEIL(v_rest / v_months * 100) / 100, 'target_date', v_date, 'months', v_months,
            'first_payment_date', v_first);
    ELSIF v_rate IS NOT NULL THEN
        -- Raten-getrieben: Zieldatum aus Ziel / Rate.
        IF v_rate <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Monthly savings rate must be a positive number, got ' || v_rate || '.');
        END IF;
        v_months := CEIL(v_rest / v_rate)::int;
        RETURN jsonb_build_object('ok', true,
            'monthly_rate', v_rate,
            'target_date', (v_first + (v_months || ' months')::interval)::date,
            'months', v_months,
            'first_payment_date', v_first);
    ELSE
        RETURN jsonb_build_object('ok', false,
            'reason', 'Provide either a target_date (then the monthly rate is computed) or a monthly_savings_rate (then the target date is computed).');
    END IF;
END;
$$;
