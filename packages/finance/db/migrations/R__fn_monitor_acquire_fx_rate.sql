-- ============================================================
-- fn_monitor_acquire_fx_rate (READ-ONLY — acquire_fn der Monitor-Methode 'fx_rate')
--   Registriert ueber den manifest-Block monitor_acquisition_methods (Phase B, docs/package-contract.md §3.9);
--   der Core dispatcht via agent.fn_monitor_acquire (Heartbeat-Cron + Tool-Probe). Logik 1:1 aus dem frueheren
--   fx-Zweig der Core-fn verschoben (der Core las finance.fx_rates ungeguardet).
--   As-of-Lookup auf finance.fx_rates (Idiom fn_to_eur); juengster Kurs aelter als monitor.fx_stale_days
--   (finance-Config, Default 5) -> {ok:false, reason 'stale'} (lauter Fehlerpfad — ein still gestorbener
--   FX-Cron wird so zum Telegram-Alert).
--   p: {spec: {base, quote}, as_of: 'YYYY-MM-DD', stale_days?: int (Test-Injektion)}
--   RUECKGABE: Observation {ok, value, unit, as_of, source_url} | {ok:false, reason}
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
    SELECT r.rate, r.as_of INTO v_rate, v_rate_date
      FROM finance.fx_rates r
     WHERE r.base_currency = v_base AND r.quote_currency = v_quote AND r.as_of <= v_as_of
     ORDER BY r.as_of DESC
     LIMIT 1;
    IF NOT FOUND THEN
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
