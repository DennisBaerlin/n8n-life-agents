-- ============================================================
-- career.fn_upsert_market_signals (WS-4 — atomarer Markt-Signal-Upsert, datierter Posting-Count-Cache)
--   Vom Cron agent.career.cron_refresh_market_signals aufgerufen (KEYLESS Bundesagentur-Jobsuche-Fetch ->
--   diese fn, KEIN LLM). Muster finance.fn_upsert_market_prices: extrahiert + still-guarded, damit die
--   Upsert-Invarianten deterministisch testbar sind (tests/db/career/test_fn_upsert_market_signals.sql) statt nur
--   im Cron-Node zu leben. Laeuft unter dem Haupt-RW-Cred (schreibt career.market_signals).
--   (v1 NUR Posting-Count; das Gehaltsband ist nicht hier — Entgeltatlas blockt automatischen Zugriff,
--    Gehalt liefert der Advisor on-demand via web_search; strukturiertes Band via Destatis GENESIS = BACKLOG.)
--
--   p = { "as_of":  "2026-06-29",                  (optional, default CURRENT_DATE)
--         "source": "bundesagentur",               (optional)
--         "signals": [                             (Pflicht: Array; je Eintrag eine market_signals-Zeile)
--           { "kind":"postings", "primary":"<Rolle>", "secondary":"<Ort>", "postings_count":120, "raw":{...} } ] }
--   scope_key baut career.fn_market_scope_key aus rohen Feldern (EINE Quelle, Write==Read).
--
--   STILL-GUARDED (kein RAISE, kein Owner-Alert): Eintrag ohne kind/primary -> skip; postings_count nur
--   uebernommen, wenn ganzzahlig (sonst NULL -> faengt "n/a"/leer ab, KEIN ::int-RAISE). ON CONFLICT
--   (scope_key, as_of) -> idempotenter Tages-Upsert.
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_upsert_market_signals.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_upsert_market_signals(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_as_of  date := COALESCE(NULLIF(p->>'as_of','')::date, CURRENT_DATE);
    v_source text := COALESCE(NULLIF(p->>'source',''), 'bundesagentur');
    v_sig    jsonb;
    v_key    text;
    v_count  int := 0;
BEGIN
    IF p->'signals' IS NULL OR jsonb_typeof(p->'signals') <> 'array' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'no signals array in payload', 'upserted', 0);
    END IF;

    FOR v_sig IN SELECT * FROM jsonb_array_elements(p->'signals') LOOP
        -- kind + primary Pflicht; sonst still skip (kein leerer/halber scope_key)
        CONTINUE WHEN COALESCE(NULLIF(trim(v_sig->>'kind'), ''), '') = ''
                   OR COALESCE(NULLIF(trim(v_sig->>'primary'), ''), '') = '';

        v_key := career.fn_market_scope_key(v_sig->>'kind', v_sig->>'primary', v_sig->>'secondary');

        INSERT INTO career.market_signals (scope_key, as_of, postings_count, source, raw, updated_at)
        VALUES (
            v_key, v_as_of,
            CASE WHEN (v_sig->>'postings_count') ~ '^[0-9]+$' THEN (v_sig->>'postings_count')::int END,
            v_source,
            COALESCE(v_sig->'raw', '{}'::jsonb),
            NOW())
        ON CONFLICT (scope_key, as_of) DO UPDATE SET
            postings_count = COALESCE(EXCLUDED.postings_count, career.market_signals.postings_count),
            source         = EXCLUDED.source,
            raw            = EXCLUDED.raw,
            updated_at     = NOW();
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'upserted', v_count, 'as_of', v_as_of);
END $$;
