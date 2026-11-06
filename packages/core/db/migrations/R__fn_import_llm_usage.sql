-- ============================================================
-- core.fn_import_llm_usage(p) — Gateway-Mitschrift (usage.jsonl, GET /__usage) nach core.llm_usage einspielen
--   p: { rows: [ {id, t, wf, model, keepalive, status, input_tokens, cache_creation_input_tokens,
--                 ephemeral_1h_input_tokens, cache_read_input_tokens, output_tokens, web_search_requests}, ... ] }
--   Idempotent ueber id (ON CONFLICT DO NOTHING): die Abrufe ueberlappen bewusst um 10 Min (Uhr-Spruenge).
--   Ungueltige Zeilen werden uebersprungen und gezaehlt — nie RAISE, eine kaputte Zeile darf weder den Report noch die
--   anderen Zeilen derselben Seite blockieren: Vorfilter (id-Form, ISO-Zeitstempel, Zaehler ganze Zahlen >= 0, Websuche
--   hoechstens 9 Stellen), dann je Zeile ein eigener Block, der auch unmoegliche Daten (30. Februar) abfaengt. Zeilen mehr
--   als einen Tag in der Zukunft (Gateway-Uhr falsch, z. B. vor NTP) werden verworfen. Ungueltiger Workflow-Name -> wf NULL.
--   Raeumt Zeilen aelter als 13 Monate weg (inline, kein Cron).
--   rows kein Array -> RAISE (Bau-Fehler des Aufrufers; der /kosten-Sub ist fail-open).
--   RUECKGABE: {ok:true, imported, skipped, after} — skipped = ungueltig/Zukunft (schon vorhandene ids zaehlen nicht); after = 13-stellige Epoch-ms der juengsten Zeile bis jetzt minus
--   10 Min (Cursor fuer den naechsten GET /__usage?after=; eine Zukunfts-Zeile kann ihn nie festnageln), NULL bei leerer
--   Tabelle. Ein Aufruf mit rows:[] liefert nur den Cursor.
--   Laeuft unter der n8n-Schreib-Credential (INVOKER, Muster fn_record_ingress_message).
--   Tests: tests/db/core/test_fn_import_llm_usage.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_import_llm_usage(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_rows     jsonb := p->'rows';
    v_total    int;
    v_imported int := 0;
    v_dup      int := 0;
    v_n        int;
    v_max_ts   timestamptz;
    e          jsonb;
    v_ts       timestamptz;
BEGIN
    IF jsonb_typeof(v_rows) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'fn_import_llm_usage: rows must be an array';
    END IF;
    v_total := jsonb_array_length(v_rows);

    FOR e IN
        SELECT x.e
          FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS x(e, ord)
         WHERE jsonb_typeof(x.e) = 'object'
           AND COALESCE(x.e->>'id', '') ~ '^[0-9]{13}-[0-9a-f]{6}-[0-9]{6}$'
           AND COALESCE(x.e->>'t', '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$'
           AND NOT EXISTS (
               SELECT 1 FROM unnest(ARRAY['input_tokens', 'cache_creation_input_tokens', 'ephemeral_1h_input_tokens',
                                          'cache_read_input_tokens', 'output_tokens']) k
                WHERE x.e ? k AND (jsonb_typeof(x.e->k) IS DISTINCT FROM 'number' OR (x.e->>k) !~ '^[0-9]{1,15}$'))
           AND (NOT x.e ? 'web_search_requests'
                OR (jsonb_typeof(x.e->'web_search_requests') = 'number' AND (x.e->>'web_search_requests') ~ '^[0-9]{1,9}$'))
         ORDER BY x.ord   -- Dublette im selben Abruf: die erste Zeile gilt
    LOOP
        BEGIN
            v_ts := (e->>'t')::timestamptz;
            CONTINUE WHEN v_ts > now() + interval '1 day';
            INSERT INTO core.llm_usage (id, ts, wf, model, keepalive, status, input_tokens, cache_creation_input_tokens,
                                        ephemeral_1h_input_tokens, cache_read_input_tokens, output_tokens, web_search_requests)
            VALUES (e->>'id',
                    v_ts,
                    CASE WHEN e->>'wf' ~ '^[a-z0-9._-]{1,80}$' THEN e->>'wf' END,
                    left(e->>'model', 128),
                    COALESCE(e->'keepalive' = 'true'::jsonb, false),
                    CASE WHEN COALESCE(e->>'status', '') ~ '^[0-9]{3}$' THEN (e->>'status')::int END,
                    COALESCE((e->>'input_tokens')::bigint, 0),
                    COALESCE((e->>'cache_creation_input_tokens')::bigint, 0),
                    COALESCE((e->>'ephemeral_1h_input_tokens')::bigint, 0),
                    COALESCE((e->>'cache_read_input_tokens')::bigint, 0),
                    COALESCE((e->>'output_tokens')::bigint, 0),
                    COALESCE((e->>'web_search_requests')::int, 0))
            ON CONFLICT (id) DO NOTHING;
            GET DIAGNOSTICS v_n = ROW_COUNT;
            IF v_n = 1 THEN v_imported := v_imported + 1; ELSE v_dup := v_dup + 1; END IF;   -- schon da = kein Fehler
        EXCEPTION WHEN data_exception OR check_violation THEN
            NULL;   -- unmoegliches Datum o. ae.: Zeile zaehlt als uebersprungen
        END;
    END LOOP;

    DELETE FROM core.llm_usage WHERE ts < now() - interval '13 months';

    SELECT max(ts) INTO v_max_ts FROM core.llm_usage WHERE ts <= now();
    RETURN jsonb_build_object(
        'ok', true,
        'imported', v_imported,
        'skipped', v_total - v_imported - v_dup,
        'after', CASE WHEN v_max_ts IS NOT NULL
                      THEN lpad(((extract(epoch FROM v_max_ts) * 1000)::bigint - 600000)::text, 13, '0') END);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_import_llm_usage(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_import_llm_usage(jsonb) FROM context_ro;
    END IF;
END $$;
