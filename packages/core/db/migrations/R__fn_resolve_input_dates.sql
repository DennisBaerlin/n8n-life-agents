-- ============================================================
-- core.fn_resolve_input_dates (DATUMS-KEYS EINES TOOL-PAYLOADS EINMAL AUFLOESEN)
--   Der eine Einstieg der Paket-Write-fns fuer relative Datumsangaben (das LLM gibt "yesterday", "in 2 weeks" roh
--   weiter, die DB rechnet): jeder Key aus p_keys, der in p als nicht-leerer Wert steht, laeuft durch
--   core.fn_resolve_date (Tag genau, Haushalts-Zeitzone; ISO bleibt -> idempotent).
--   Ergebnis:
--     {ok:true, p:<p mit ISO-Werten>, resolved:{<key>:'YYYY-MM-DD',…}}
--     {ok:false, code:'invalid_date', reason:'<key> must be …'}   (erster nicht aufloesbarer Key; kein RAISE)
--   Fehlende Keys, '' und JSON-null bleiben unberuehrt (die fn des Aufrufers setzt ihren Default). Ein Nicht-String
--   (z. B. eine Zahl) unter einem Datums-Key ist ungueltig.
--   Aufruf-Muster (erste Anweisung im Body, Datums-Casts erst danach — nie im DECLARE):
--     v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
--     IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
--     p := v_dates->'p';
--   und jeder Erfolgs-Return meldet 'effective', (v_dates->'resolved') || COALESCE(<eigenes effective>, '{}'),
--   damit der echte Write nach der Karte dasselbe Datum bekommt (New-FnWriteGate, auch nach Mitternacht).
--   Der Grund-Text verweist auf die Parameter-Beschreibung (Get-DateParamHint = die eine Adresse der Grammatik).
--   Aufrufer: die finance-/estate-Write-fns (Drift-Guard tests/db/finance/test_fn_relative_dates.sql).
--   STABLE, INVOKER, ohne Tabellenzugriff. Paket-Rollen: EXECUTE-Grant in core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_resolve_input_dates.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_resolve_input_dates(p jsonb, p_keys text[], p_today date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_out  jsonb := COALESCE(p, '{}'::jsonb);
    v_res  jsonb := '{}'::jsonb;
    v_key  text;
    v_val  jsonb;
    v_d    date;
BEGIN
    FOREACH v_key IN ARRAY COALESCE(p_keys, ARRAY[]::text[]) LOOP
        v_val := v_out -> v_key;
        CONTINUE WHEN v_val IS NULL OR jsonb_typeof(v_val) = 'null'
                   OR (jsonb_typeof(v_val) = 'string' AND btrim(v_val #>> '{}') = '');
        v_d := CASE WHEN jsonb_typeof(v_val) = 'string'
                    THEN core.fn_resolve_date(v_val #>> '{}', p_today) END;   -- late-bound: plpgsql
        IF v_d IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_date', 'reason',
                v_key || ' "' || (v_val #>> '{}') || '" is not a date the database can read - give YYYY-MM-DD or a '
                      || 'relative form from the parameter description, or ask the user for the exact day.');
        END IF;
        v_out := v_out || jsonb_build_object(v_key, to_char(v_d, 'YYYY-MM-DD'));
        v_res := v_res || jsonb_build_object(v_key, to_char(v_d, 'YYYY-MM-DD'));
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'p', v_out, 'resolved', v_res);
END;
$$;
