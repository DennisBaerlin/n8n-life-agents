-- ============================================================
-- career.fn_upsert_market_signals (ATOMIC UPSERT)
--   Atomarer Markt-Signal-Upsert (datierter Posting-Count-Cache), vom Cron agent.career.cron_refresh_market_signals
--   aufgerufen (keyless Bundesagentur-Jobsuche-Fetch -> diese fn, kein LLM). Muster finance.fn_upsert_market_prices:
--   extrahiert + still-guarded, damit die Upsert-Invarianten deterministisch testbar sind
--   (tests/db/career/test_fn_upsert_market_signals.sql) statt nur im Cron-Node zu leben. Laeuft unter dem
--   Haupt-RW-Cred (schreibt career.market_signals). Nur Posting-Count; das Gehaltsband liefert der Advisor
--   on-demand via web_search (Entgeltatlas blockt automatischen Zugriff).
--
--   p = { "as_of":  "2026-06-29",                  (optional, default CURRENT_DATE)
--         "source": "bundesagentur",               (optional)
--         "signals": [                             (Pflicht: Array; je Eintrag eine market_signals-Zeile)
--           { "kind":"postings", "primary":"<Rolle>", "secondary":"<Ort>", "postings_count":120, "raw":{...} } ] }
--   scope_key baut career.fn_market_scope_key aus rohen Feldern (eine Quelle, Write==Read).
--
--   Rueckgabe: {ok:true, upserted, as_of}; ohne signals-Array {ok:false, reason:'no signals array in payload',
--   upserted:0}; ungueltiges as_of {ok:false, reason:'invalid as_of "..." (expected YYYY-MM-DD)', upserted:0}.
--   Einzelne Eintraege still-guarded (kein RAISE, kein Owner-Alert): ohne kind/primary -> skip; postings_count
--   nur uebernommen, wenn ganzzahlig (sonst NULL, faengt "n/a"/leer ab, kein ::int-RAISE). ON CONFLICT
--   (scope_key, as_of) -> idempotenter Tages-Upsert (COALESCE-Merge des postings_count).
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_upsert_market_signals(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_as_of  date;
    v_source text := COALESCE(NULLIF(p->>'source',''), 'bundesagentur');
    v_sig    jsonb;
    v_key    text;
    v_count  int := 0;
BEGIN
    IF p->'signals' IS NULL OR jsonb_typeof(p->'signals') <> 'array' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'no signals array in payload', 'upserted', 0);
    END IF;
    -- Pruefen vor dem Cast: ein ungueltiges as_of ist korrigierbar und kommt als Daten zurueck, kein RAISE.
    IF NULLIF(p->>'as_of','') IS NOT NULL AND NOT pg_input_is_valid(p->>'as_of', 'date') THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('invalid as_of "%s" (expected YYYY-MM-DD)', p->>'as_of'), 'upserted', 0);
    END IF;
    v_as_of := COALESCE(NULLIF(p->>'as_of','')::date, CURRENT_DATE);

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
