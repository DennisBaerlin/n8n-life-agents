-- ============================================================
-- fn_warning_due_soon (READ, STABLE) — ist ein Problem-Datum einer Berater-Warnung bald?
--   Die eine Regel fuer "echte Gefahr" im Plan-Gespraech: der Finanzberater schickt die Liste vereinbarter Punkte mitten im
--   Plan nur fuer eine Warnung, deren Problem bald eintritt; weiter entfernte Warnungen warten bis nach dem Plan.
--   Bald = p_on <= core.fn_today() + finance.advisor.handoff_urgent_days (Default 30; fehlend oder unlesbar -> 30).
--   Ein schon erreichtes Datum ist bald. Eingabe p_on date (NULL -> false). Rueckgabe boolean.
--   INVOKER (finance_ro im Snapshot), nie RAISE.
--   Aufrufer: finance.fn_advisor_snapshot (warnings[].due_soon).
--   Tests: tests/db/finance/test_fn_warning_due_soon.sql, tests/db/finance/test_fn_advisor_snapshot.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_warning_due_soon(p_on date)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_days int;
BEGIN
    IF p_on IS NULL THEN
        RETURN false;
    END IF;
    BEGIN
        v_days := NULLIF(core.fn_config_get('finance', 'advisor', 'handoff_urgent_days'), '')::int;
    EXCEPTION WHEN OTHERS THEN
        v_days := NULL;
    END;
    RETURN p_on <= core.fn_today() + COALESCE(v_days, 30);
END;
$$;
