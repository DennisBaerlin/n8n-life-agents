-- ============================================================
-- fn_monitor_acquire_fx_rate (READ-ONLY — acquire_fn der Monitor-Methode 'fx_rate')
--   Registriert ueber den manifest-Block monitor_acquisition_methods (docs/package-contract.md §3.9);
--   der Core dispatcht via agent.fn_monitor_acquire (Heartbeat-Cron + Tool-Probe).
--   Kurs ueber finance.fn_fx_rate (jedes Paar: direkt, invers oder ueber EUR gekreuzt; as_of = aelteres der beiden
--   Kurs-Daten). Kurs aelter als monitor.fx_stale_days (finance-Config, Default 5) -> {ok:false, reason: 'fx rate ...
--   is stale ...'} (lauter Fehlerpfad je Waechter). Eine Seite ohne Kurs-Zeile am oder vor dem Stichtag -> {ok:false, reason: 'no fx rate ...'}.
--   p: {spec: {base, quote}, as_of?: 'YYYY-MM-DD' (Default heute), stale_days?: int (Test-Injektion)}
--   Rueckgabe: Observation {ok:true, value, unit, as_of, source_url} | {ok:false, reason}
--   Tests: tests/db/finance/test_fn_monitor_acquire_fx_rate.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_monitor_acquire_fx_rate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base      text := upper(trim(COALESCE(p->'spec'->>'base', '')));
    v_quote     text := upper(trim(COALESCE(p->'spec'->>'quote', '')));
    v_as_of     date := COALESCE(NULLIF(p->>'as_of', '')::date, CURRENT_DATE);
    v_stale     int  := COALESCE(NULLIF(p->>'stale_days', '')::int,
                                 NULLIF(core.fn_config_get('finance', 'monitor', 'fx_stale_days'), '')::int, 5);
    v_rate      numeric;
    v_rate_date date;
BEGIN
    SELECT f.rate, f.as_of INTO v_rate, v_rate_date FROM finance.fn_fx_rate(v_base, v_quote, v_as_of) f;
    -- ein Kurs erst nach dem Stichtag (Rueckfall in fn_fx_eur_row) ist keine Beobachtung fuer diesen Tag, je Seite geprueft:
    -- fn_fx_rate meldet nur das aeltere der beiden Daten
    IF v_rate IS NULL OR EXISTS (
        SELECT 1 FROM unnest(ARRAY[v_base, v_quote]) s(code)
        CROSS JOIN LATERAL finance.fn_fx_eur_row(s.code::char(3), v_as_of) e
        WHERE e.as_of > v_as_of) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('no fx rate for %s/%s in the finance fx table', v_base, v_quote));
    END IF;
    IF v_rate_date < v_as_of - v_stale THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('fx rate %s/%s is stale (last %s, older than %s days)', v_base, v_quote, v_rate_date, v_stale));
    END IF;
    RETURN jsonb_build_object('ok', true, 'value', v_rate,
        'unit', format('%s per %s', v_quote, v_base),
        'as_of', v_rate_date::text, 'source_url', 'finance.fx_rates');
END;
$$;
