-- tests/db/core/test_fn_import_llm_usage.sql
-- core.fn_import_llm_usage(p) — Import der Gateway-Mitschrift (usage.jsonl via GET /__usage) nach core.llm_usage:
--   idempotent ueber id (zweiter Import = 0 neu), ungueltige Zeilen werden gezaehlt und uebersprungen (nie RAISE),
--   ungueltiger Workflow-Name -> wf NULL ("Sonstige"), Retention 13 Monate inline, `after` = Cursor fuer den
--   naechsten Abruf (13-stellige ms von max(ts) minus 10 Min Ueberlappung). rows kein Array -> RAISE (Bau-Fehler).
--   Unmoegliche Daten / zu grosse Zahlen brechen die Seite nicht ab; Zeilen > 1 Tag in der Zukunft werden verworfen.
BEGIN;

DO $$
DECLARE
  r JSONB; v_n int; v_wf text; v_ka boolean;
  -- Zeitstempel relativ zu jetzt (sonst raeumte die 13-Monats-Retention feste Daten irgendwann selbst weg)
  t0 timestamptz := date_trunc('second', now()) - interval '1 hour';
  ms0 bigint;
BEGIN
  ms0 := (extract(epoch FROM t0) * 1000)::bigint;
  DELETE FROM core.llm_usage;
  -- leere Tabelle: ok, nichts neu, kein Cursor
  r := core.fn_import_llm_usage('{"rows":[]}');
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'imported')::int <> 0 OR r->'after' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [leer]: %', r; END IF;

  -- uralte Zeile direkt anlegen (Retention-Probe)
  INSERT INTO core.llm_usage (id, ts, wf, model) VALUES ('0000000000001-aaaaaa-000001', now() - interval '14 months', 'agent.old', 'zz-model-a');

  r := core.fn_import_llm_usage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('id', lpad(ms0::text, 13, '0') || '-0a1b2c-000001', 't', to_char(t0 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                       'wf','agent.finance','model','claude-sonnet-5-5',
                       'input_tokens',10,'cache_creation_input_tokens',100,'ephemeral_1h_input_tokens',80,'cache_read_input_tokens',50,
                       'output_tokens',7,'web_search_requests',1,'status',200),
    jsonb_build_object('id', lpad((ms0 + 60000)::text, 13, '0') || '-0a1b2c-000002', 't', to_char((t0 + interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                       'wf','agent.finance','model','claude-sonnet-5-5','keepalive',true,'cache_read_input_tokens',48000,'status',200),
    jsonb_build_object('id', lpad((ms0 + 120000)::text, 13, '0') || '-0a1b2c-000003', 't', to_char((t0 + interval '2 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                       'wf','bad name; drop','model','claude-haiku-5-5','status',200),
    jsonb_build_object('id','kaputt','t', to_char(t0 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),        -- ungueltige id
    jsonb_build_object('id', lpad((ms0 + 240000)::text, 13, '0') || '-0a1b2c-000005', 't', to_char(t0 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                       'input_tokens',-5),                                                                           -- negativ
    jsonb_build_object('id', lpad((ms0 + 300000)::text, 13, '0') || '-0a1b2c-000006', 't','kein-datum'),          -- kein Zeitstempel
    jsonb_build_object('id', lpad(ms0::text, 13, '0') || '-0a1b2c-000001', 't', to_char(t0 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                       'input_tokens',999)                                                                           -- Dublette
  )));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'imported')::int <> 3 OR (r->>'skipped')::int <> 3 THEN
    RAISE EXCEPTION 'FAIL [3 neu, 3 ungueltig, Dublette still]: %', r; END IF;
  SELECT count(*) INTO v_n FROM core.llm_usage WHERE id = '0000000000001-aaaaaa-000001';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [Retention 13 Monate]'; END IF;
  SELECT wf INTO v_wf FROM core.llm_usage WHERE id = lpad((ms0 + 120000)::text, 13, '0') || '-0a1b2c-000003';
  IF v_wf IS NOT NULL THEN RAISE EXCEPTION 'FAIL [ungueltiger wf -> NULL]: %', v_wf; END IF;
  SELECT keepalive INTO v_ka FROM core.llm_usage WHERE id = lpad((ms0 + 60000)::text, 13, '0') || '-0a1b2c-000002';
  IF v_ka IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [keepalive uebernommen]'; END IF;
  SELECT count(*) INTO v_n FROM core.llm_usage
   WHERE id = lpad(ms0::text, 13, '0') || '-0a1b2c-000001' AND input_tokens = 10 AND cache_creation_input_tokens = 100
     AND ephemeral_1h_input_tokens = 80 AND cache_read_input_tokens = 50 AND output_tokens = 7 AND web_search_requests = 1
     AND status = 200 AND wf = 'agent.finance' AND model = 'claude-sonnet-5-5' AND ts = t0;
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [Werte der ersten Zeile, Dublette ueberschreibt nicht]'; END IF;
  -- Cursor: max(ts) = t0 + 2 Min -> minus 10 Min = ms0 - 480000
  IF r->>'after' <> lpad((ms0 - 480000)::text, 13, '0') THEN
    RAISE EXCEPTION 'FAIL [Cursor = max(ts) - 10 Min]: % (erwartet %)', r->>'after', ms0 - 480000; END IF;

  -- Seite mit unmoeglichem Datum, zu grosser Websuche-Zahl und einer Zukunfts-Zeile: nur die gueltige Zeile kommt rein,
  -- die Seite bricht nicht ab, und die Zukunfts-Zeile nagelt den Cursor nicht fest
  r := core.fn_import_llm_usage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('id', lpad((ms0 + 360000)::text, 13, '0') || '-0a1b2c-000007', 't', '2026-02-30T10:00:00Z'),
    jsonb_build_object('id', lpad((ms0 + 420000)::text, 13, '0') || '-0a1b2c-000008', 't', to_char(t0 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                       'web_search_requests', 3000000000),
    jsonb_build_object('id', lpad((ms0 + 500000000)::text, 13, '0') || '-0a1b2c-000009', 't', to_char((now() + interval '3 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
    jsonb_build_object('id', lpad((ms0 + 180000)::text, 13, '0') || '-0a1b2c-000010', 't', to_char((t0 + interval '3 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                       'wf', 'agent.guide', 'output_tokens', 5)
  )));
  IF (r->>'imported')::int <> 1 OR (r->>'skipped')::int <> 3 THEN RAISE EXCEPTION 'FAIL [kaputte Zeilen blockieren die Seite nicht]: %', r; END IF;
  IF r->>'after' <> lpad((ms0 + 180000 - 600000)::text, 13, '0') THEN
    RAISE EXCEPTION 'FAIL [Zukunfts-Zeile verschiebt den Cursor nicht]: % (erwartet %)', r->>'after', ms0 + 180000 - 600000; END IF;

  -- zweiter Import derselben Zeile: nichts neu
  r := core.fn_import_llm_usage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('id', lpad(ms0::text, 13, '0') || '-0a1b2c-000001', 't', to_char(t0 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), 'wf','agent.finance'))));
  IF (r->>'imported')::int <> 0 OR (r->>'skipped')::int <> 0 THEN RAISE EXCEPTION 'FAIL [idempotent, vorhandene id ist kein Fehler]: %', r; END IF;

  -- rows kein Array -> RAISE
  BEGIN
    PERFORM core.fn_import_llm_usage('{"rows":{}}');
    RAISE EXCEPTION 'FAIL [rows kein Array muss werfen]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'PASS test_fn_import_llm_usage (idempotent, ungueltig uebersprungen, wf NULL, Retention, Cursor)';
END $$;

ROLLBACK;
