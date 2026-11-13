-- ============================================================
-- fn_savings_squeeze_fold (INTERNAL HELPER — Event-Fold, nicht tool-facing)
--   Der eine savings_squeeze-Sofort-Hinweis der Sparraten-Write-fns fn_create_savings_goal, fn_set_savings_goal und
--   fn_set_savings_plan (Muster fn_cashflow_coverage_fold). Liest den Post-State nach dem Write aus
--   finance.monthly_cashflow_summary: bei monthly_income > 0 und monthly_account_change < 0 uebersteigen die
--   Sparraten (Sparplan + Sparziel-Raten + Vorsorge) das frei Verfuegbare -> das Girokonto schrumpft. Bei schon
--   negativem monthly_free eigener Text (die Raten vertiefen ein bestehendes Pflicht-Defizit).
--   Ueber core.fn_should_notify gelatcht (Singleton-Key, TTL 24h); Erholung (monthly_income > 0 und
--   monthly_account_change >= 0) -> core.fn_notify_resolve (expliziter Re-Arm, Paritaet cashflow_coverage).
--   Ohne Einnahmen weder Hinweis noch Re-Arm (diesen Fall meldet cashflow_coverage).
--   Grenze: ein Sparplan-Split mit kuenftigem valid_from ist im Post-State noch nicht sichtbar (wie cashflow_coverage);
--   der periodische Advisor-Cron bleibt der Backstop.
--   Nicht-blockierend: der Aufrufer faltet das Ergebnis in seinen {ok:true}-Return, der Bookkeeper relayed die note.
--   frei und Kontoveraenderung rechnen den geschaetzten Alltag ein (fn_household_everyday_month).
--   Eingabe: p_chat_id (optional) = Absender; hoerte der Owner die Notiz, merkt core.fn_mark_told das fuer den Waechter.
--   RUECKGABE jsonb: '{}' oder {savings_squeeze: {account_change, note}}.
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_savings_squeeze_fold();
CREATE OR REPLACE FUNCTION finance.fn_savings_squeeze_fold(p_chat_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_income NUMERIC;
    v_change NUMERIC;
    v_free   NUMERIC;
    v_ev     RECORD;
BEGIN
    SELECT monthly_income, monthly_account_change, monthly_free
      INTO v_income, v_change, v_free
    FROM finance.monthly_cashflow_summary;
    SELECT * INTO v_ev FROM finance.fn_household_everyday_month();
    v_free   := v_free + v_ev.monthly_everyday;
    v_change := v_change + v_ev.monthly_everyday;

    IF v_income > 0 AND v_change < 0 THEN
        IF core.fn_should_notify('finance', 'savings_squeeze', interval '24 hours') THEN
            PERFORM core.fn_mark_told('finance', p_chat_id, 'savings_squeeze');
            RETURN jsonb_build_object('savings_squeeze', jsonb_build_object(
                'account_change', round(v_change, 2),
                'note', CASE WHEN v_free < 0
                             THEN 'Warning: spending, loan instalments and estimated everyday spending already exceed income; with the current savings '
                                  || 'rates the current account shrinks by about ' || round(abs(v_change), 2)
                                  || ' EUR/month. Levers: lower a savings rate, cut expenses or raise income.'
                             ELSE 'Warning: the savings rates exceed what remains free after spending, loan instalments and '
                                  || 'estimated everyday spending - '
                                  || 'the current account shrinks by about ' || round(abs(v_change), 2)
                                  || ' EUR/month. Levers: lower a savings rate or cut expenses.' END));
        END IF;
    ELSIF v_income > 0 THEN
        PERFORM core.fn_notify_resolve('finance', 'savings_squeeze');
    END IF;
    RETURN '{}'::jsonb;
END;
$$;
