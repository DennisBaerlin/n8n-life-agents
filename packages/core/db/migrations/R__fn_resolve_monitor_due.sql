-- ============================================================
-- agent.fn_resolve_monitor_due (die EINE Faelligkeits-Regel der date-Trigger)
--   Loest due_date ueber core.fn_resolve_date auf (YYYY-MM-DD oder relativ "+6 months" — das LLM rechnet nie) und
--   prueft "nicht in der Vergangenheit". EINE Quelle fuer die Write-fns (fn_create_/fn_set_monitor_trigger) UND die
--   Karten-Vorstufe der Tools (Probe bzw. Resolve trigger), damit Karte und Write dieselbe Regel und dasselbe Datum
--   haben (kein Tipp auf eine Karte, die der Write danach ablehnt).
--   RUECKGABE: {ok:true, due_date:'YYYY-MM-DD'} | {ok:false, reason}. NULL/leer -> {ok:false} (der Aufrufer entscheidet,
--   ob ein Datum Pflicht ist).
--   STABLE. Tests: tests/db/core/test_fn_resolve_monitor_due.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_resolve_monitor_due(p_text text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_due date := core.fn_resolve_date(p_text);
BEGIN
    IF v_due IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'due_date must be YYYY-MM-DD or relative to today (e.g. +6 months, in 3 weeks)');
    END IF;
    IF v_due < core.fn_today() THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('due_date %s is in the past', v_due));
    END IF;
    RETURN jsonb_build_object('ok', true, 'due_date', to_char(v_due, 'YYYY-MM-DD'));
END;
$$;
