-- ============================================================
-- test_fn_fx_metal_due — welche Tage der FX-Cron je Edelmetall holt (finance.fn_fx_metal_due)
--   Eine Zeile je Metall aus finance.currencies (kind = 'metal'); ohne Metall-Zeile 5 Jahre bis heute (UTC), sonst ab dem
--   juengsten Tag des Metalls (der wird neu geholt, der Mischkurs zieht im Lauf des Tages nach); je Metall getrennt.
--   Rollen-Perspektive finance_rw (der FX-Cron). BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE v_utc date := (now() AT TIME ZONE 'UTC')::date; v jsonb;
BEGIN
    DELETE FROM finance.fx_rates WHERE quote_currency IN ('XAU', 'XAG');
    SELECT jsonb_object_agg(m.metal, jsonb_build_object('from', m.from_date, 'to', m.to_date)) INTO v
    FROM finance.fn_fx_metal_due() m;
    IF v IS DISTINCT FROM jsonb_build_object(
         'XAU', jsonb_build_object('from', (core.fn_today() - interval '5 years')::date, 'to', v_utc),
         'XAG', jsonb_build_object('from', (core.fn_today() - interval '5 years')::date, 'to', v_utc)) THEN
        RAISE EXCEPTION 'FAIL [ohne Metall-Zeile -> 5 Jahre je Metall]: %', v;
    END IF;
    -- Gold zuletzt gestern, Silber heute: je Metall ab seinem juengsten Tag
    PERFORM finance.fn_upsert_fx_rates(jsonb_build_object('rows', jsonb_build_array(
        jsonb_build_object('date', (v_utc - 1)::text, 'base', 'XAU', 'quote', 'EUR', 'rate', 3236.31),
        jsonb_build_object('date', v_utc::text, 'base', 'XAG', 'quote', 'EUR', 'rate', 37.4))));
    SELECT jsonb_object_agg(m.metal, jsonb_build_object('from', m.from_date, 'to', m.to_date)) INTO v
    FROM finance.fn_fx_metal_due() m;
    IF v IS DISTINCT FROM jsonb_build_object(
         'XAU', jsonb_build_object('from', v_utc - 1, 'to', v_utc),
         'XAG', jsonb_build_object('from', v_utc, 'to', v_utc)) THEN
        RAISE EXCEPTION 'FAIL [juengster Tag je Metall, heute wird nachgezogen]: %', v;
    END IF;
    -- eine EZB- oder Feed-Zeile beeinflusst die Metalle nicht
    PERFORM finance.fn_ensure_currency('USD');
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
    VALUES ('EUR', 'USD', 1.1, v_utc, finance.fn_fx_feed_source());
    IF (SELECT m.from_date FROM finance.fn_fx_metal_due() m WHERE m.metal = 'XAU') IS DISTINCT FROM v_utc - 1 THEN
        RAISE EXCEPTION 'FAIL [Feed-Zeile verschiebt den Metall-Zeitraum]';
    END IF;
    SET LOCAL ROLE finance_rw;
    PERFORM count(*) FROM finance.fn_fx_metal_due();
    RESET ROLE;
    RAISE NOTICE 'PASS test_fn_fx_metal_due [5 Jahre ohne Zeile, je Metall ab juengstem Tag, finance_rw]';
END $$;
ROLLBACK;
