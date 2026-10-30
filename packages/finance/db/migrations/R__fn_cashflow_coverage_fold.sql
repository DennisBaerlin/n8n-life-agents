-- ============================================================
-- fn_cashflow_coverage_fold (INTERNAL HELPER — Event-Fold, nicht tool-facing)
--   Der EINE cashflow_coverage-Sofort-Hinweis der Write-fns fn_create_recurring_payment und fn_set_recurring_payment
--   (zweiter Konsument -> vereinheitlicht, Audit Paket 3). Liest den Post-State NACH dem Write aus
--   finance.monthly_cashflow_summary: monthly_free < 0 = die Pflichtausgaben (Konsum inkl. Kreditzins + Tilgung)
--   uebersteigen die Einnahmen; Sparraten zaehlen nicht (die meldet savings_squeeze). Auch OHNE Einnahmen (das letzte
--   Gehalt endet) -> Hinweis. Keine laufende Zahlung = neutral (leere/halb-onboardete DB).
--   Phase Notify: ueber core.fn_should_notify gelatcht (Singleton-Key, TTL 48h = Backstop fuer den valid_to-Ablauf-
--   Erholungspfad ohne Schreib-Edge); frei >= 0 -> core.fn_notify_resolve (expliziter Re-Arm).
--   Nicht-blockierend: der Aufrufer faltet das Ergebnis in seinen {ok:true}-Return, der Bookkeeper relayed die note.
--   Seit 2026-10-30 (Transparenz, Owner-Entscheid) rechnet „frei“ den geschaetzten Alltag ein
--   (finance.fn_household_everyday_month, dieselbe Adresse wie fn_advisor_review); die note nennt die Basis.
--   RUECKGABE jsonb: '{}' oder {cashflow_coverage: {monthly_free, note}}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_cashflow_coverage_fold()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_free NUMERIC;
    v_rows BIGINT;
    v_ev   RECORD;
BEGIN
    SELECT monthly_free, income_count + consumption_count + loan_count + saving_count
      INTO v_free, v_rows
    FROM finance.monthly_cashflow_summary;
    SELECT * INTO v_ev FROM finance.fn_household_everyday_month();
    v_free := v_free + v_ev.monthly_everyday;

    IF v_rows > 0 AND v_free < 0 THEN
        IF core.fn_should_notify('finance', 'cashflow_coverage', interval '48 hours') THEN
            RETURN jsonb_build_object('cashflow_coverage', jsonb_build_object(
                'monthly_free', round(v_free, 2),
                'note', 'Warning: the running obligations (spending and loan instalments, savings rates not included) '
                        || CASE WHEN v_ev.accounts > 0 THEN 'plus everyday spending estimated from bank statements (about '
                                     || round(abs(v_ev.monthly_everyday), 2) || ' EUR/month) '
                                ELSE '(everyday spending not included yet - no bank statement) ' END
                        || 'exceed income by about ' || round(abs(v_free), 2)
                        || ' EUR/month. Levers: cut expenses, raise income, or refinance a loan.'));
        END IF;
    ELSIF v_rows > 0 THEN
        PERFORM core.fn_notify_resolve('finance', 'cashflow_coverage');
    END IF;
    RETURN '{}'::jsonb;
END;
$$;
