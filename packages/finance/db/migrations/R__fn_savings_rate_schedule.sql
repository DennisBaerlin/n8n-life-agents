-- ============================================================
-- fn_savings_rate_schedule (READ-ONLY HELPER, IMMUTABLE)
--   Berechnet die fehlende Groesse eines Sparplans DETERMINISTISCH -- damit das LLM
--   NICHT rechnet (Root-CLAUDE.md *Das LLM rechnet NICHT*). Zwei Richtungen:
--     - Ziel-getrieben: target_amount + target_date gegeben -> monthly_rate = Ziel / Monate.
--     - Raten-getrieben: target_amount + monthly_savings_rate gegeben -> target_date = first + ceil(Ziel/Rate) Monate.
--   Die Rate wird auf den Cent AUFGERUNDET (Audit Paket 2, Punkt 15): 1000 / 3 = 333.34, damit die Raten das Ziel
--   erreichen (gerundet 333.33 -> 999.99, "erreicht" feuerte nie). Sparziele sind EUR -> Cent.
--   Anker der Monatszaehlung ist first_payment_date. Wird VOM TOOL read-only fuer den HITL-Preview
--   UND von fn_create_savings_goal (autoritativ, im Write) aufgerufen -> eine Quelle, kein Drift.
--   Eingabe jsonb: target_amount, first_payment_date, plus GENAU EINES von {target_date, monthly_savings_rate}.
--   Rueckgabe: {ok:true, monthly_rate, target_date, months} ODER {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_rate_schedule(p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_target NUMERIC := NULLIF(p->>'target_amount', '')::numeric;
    v_date   DATE    := NULLIF(p->>'target_date', '')::date;
    v_rate   NUMERIC := NULLIF(p->>'monthly_savings_rate', '')::numeric;
    v_first  DATE    := NULLIF(p->>'first_payment_date', '')::date;
    v_months INT;
BEGIN
    IF v_target IS NULL OR v_target <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Target amount must be a positive number, got ' || COALESCE(v_target::text, 'null') || '.');
    END IF;
    IF v_first IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'first_payment_date is required.');
    END IF;

    IF v_date IS NOT NULL THEN
        -- Ziel-getrieben: Rate aus Ziel / Monate (Monatsgranularitaet, Anker first_payment_date).
        IF v_date <= v_first THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Target date must be after the first payment date (' || v_first || ').');
        END IF;
        v_months := ( (EXTRACT(YEAR FROM v_date)::int * 12 + EXTRACT(MONTH FROM v_date)::int)
                    - (EXTRACT(YEAR FROM v_first)::int * 12 + EXTRACT(MONTH FROM v_first)::int) );
        v_months := GREATEST(v_months, 1);
        RETURN jsonb_build_object('ok', true,
            'monthly_rate', CEIL(v_target / v_months * 100) / 100, 'target_date', v_date, 'months', v_months);
    ELSIF v_rate IS NOT NULL THEN
        -- Raten-getrieben: Zieldatum aus Ziel / Rate.
        IF v_rate <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Monthly savings rate must be a positive number, got ' || v_rate || '.');
        END IF;
        v_months := CEIL(v_target / v_rate)::int;
        RETURN jsonb_build_object('ok', true,
            'monthly_rate', v_rate,
            'target_date', (v_first + (v_months || ' months')::interval)::date,
            'months', v_months);
    ELSE
        RETURN jsonb_build_object('ok', false,
            'reason', 'Provide either a target_date (then the monthly rate is computed) or a monthly_savings_rate (then the target date is computed).');
    END IF;
END;
$$;
