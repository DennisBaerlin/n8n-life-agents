-- ============================================================
-- fn_fx_rate_map (READ) -- EUR-Kurs je Waehrung zum heutigen Tag als jsonb {CCY: rate, EUR: 1}
--   Fuer den Plausi-Check eines Kurs-Symbol-Kandidaten in Fremdwaehrung (agent.finance.sub_resolve_yahoo_symbol,
--   Input fx_rates): Kandidaten-Kurs und Referenzkurs werden in EUR verglichen. rate = Einheiten der Waehrung je 1 EUR
--   (finance.fx_rates base EUR), aus der einen Kurs-Suche finance.fn_fx_eur_row (derselbe Kurs wie fn_to_eur; je
--   Waehrung zwei Index-Zugriffe statt eines Scans der ganzen Historie). Jede Waehrung aus finance.currencies mit einem
--   Kurs (der Tages-Abruf legt alle Feed-Waehrungen an). Die eine Adresse fuer fn_price_gaps (Kurs-Luecken-Erinnerung)
--   und tool_set_holding/tool_verify_price_symbol. Keine Eingabe.
--   Tests: tests/db/finance/test_fn_price_gaps.sql, tests/db/finance/test_fn_fx_rate.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_fx_rate_map()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('EUR', 1) || COALESCE(jsonb_object_agg(c.code, e.rate), '{}'::jsonb)
    FROM finance.currencies c
    CROSS JOIN LATERAL finance.fn_fx_eur_row(c.code, current_date) e
    WHERE c.code <> 'EUR';
$$;
