-- tests/db/core/test_fn_get_llm_cost_report.sql
-- core.fn_get_llm_cost_report(p) — Datenmodell von /costs (/kosten): KI-Kosten 7/30 Tage aus core.llm_usage x
--   agent.ai_models.pricing_usd_per_mtok. Prueft die Preis-Mathematik (Input, Cache schreiben 5m/1h, Cache lesen,
--   Output, Websuche, Langkontext-Stufe), den Warmhalte-Topf, unbepreiste Modelle, Top-N + Sonstige je Workflow,
--   je Modell, Vorwoche + Hochrechnung, Kaltstarts (Schwelle Default 20000), teuersten Tag in der Sitzungs-Zeitzone
--   (= Haushalts-Zeitzone), Cache-Trefferquote, das DB-Owner-Gate (Mitglied/unbekannt -> owner_only) und den
--   Aufruf unter core_ro (der /kosten-Sub liest unter core_ro). Alle Werte erfunden.
BEGIN;

SET LOCAL TimeZone = 'Europe/Berlin';

DO $$
DECLARE
  r JSONB; e JSONB;
  noon timestamptz := (current_date + time '12:00')::timestamptz;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'llm_cost_report fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__cr_owner__','first_name','CR','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7601,'as_of','2026-10-25'),
            jsonb_build_object('person_id','__cr_partner__','first_name','CR','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7602,'as_of','2026-10-25')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  DELETE FROM core.config WHERE category = 'cost' AND key = 'cold_start_min_tokens';

  -- Test-Modelle (mode embedding = kein Umschalter-Platz noetig; der Report kennt nur n8n_model_id + Preise)
  INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode, pricing_usd_per_mtok) VALUES
    ('zz-cost-a', 'Anthropic', 'zz-model-a', NULL, 'embedding',
     '{"input":1,"cache_write_5m":2,"cache_write_1h":4,"cache_read":0.5,"output":10,"web_search_usd_per_request":0.01}'),
    ('zz-cost-lc', 'Anthropic', 'zz-model-lc', NULL, 'embedding',
     '{"input":1,"cache_write_5m":2,"cache_write_1h":4,"cache_read":0.5,"output":10,
       "long_context":{"above_input_tokens":1000,"input":3,"cache_write_5m":6,"cache_write_1h":12,"cache_read":1.5,"output":30}}');

  DELETE FROM core.llm_usage;
  INSERT INTO core.llm_usage (id, ts, wf, model, keepalive, input_tokens, cache_creation_input_tokens,
                              ephemeral_1h_input_tokens, cache_read_input_tokens, output_tokens, web_search_requests, status) VALUES
    -- r1 heute: 1,00 Input + 1,50 Schreiben (250k 5m x 2 + 250k 1h x 4) + 1,00 Lesen + 1,00 Output + 0,10 Websuche = 4,60; Kaltstart (1h >= 20000)
    ('1000000000001-aaaaaa-000001', noon, 'agent.finance', 'zz-model-a', false, 1000000, 500000, 250000, 2000000, 100000, 10, 200),
    -- r2 heute Warmhalten: 1 Mio Lesen x 0,5 = 0,50 -> Topf keepalive
    ('1000000000002-aaaaaa-000002', noon, 'agent.finance', 'zz-model-a', true, 0, 0, 0, 1000000, 0, 0, 200),
    -- r3 heute unbekanntes Modell -> ohne Preis
    ('1000000000003-aaaaaa-000003', noon, 'agent.guide', 'unknown-model', false, 500, 0, 0, 0, 10, 0, 200),
    -- r4 vor 13 Tagen (Vorwoche, 30-Tage-Fenster): 1,00 Output; frueheste Zeile -> data_since
    ('1000000000004-aaaaaa-000004', noon - interval '13 days', 'agent.guide', 'zz-model-a', false, 0, 0, 0, 0, 100000, 0, 200),
    -- r5 heute Kaltstart: 30000 1h x 4 = 0,12
    ('1000000000005-aaaaaa-000005', noon, 'agent.finance', 'zz-model-a', false, 0, 30000, 30000, 0, 0, 0, 200),
    -- r6 heute Langkontext: 2000 Input > 1000 -> Stufe input 3 -> 0,006; ohne Workflow -> Sonstige
    ('1000000000006-aaaaaa-000006', noon, NULL, 'zz-model-lc', false, 2000, 0, 0, 0, 0, 0, 200),
    -- r7 heute 00:30 Berlin (= gestern in UTC): 1 Mio Output x 10 = 10,00 -> teuerster Tag ist HEUTE nur in Haushalts-TZ
    ('1000000000007-aaaaaa-000007', (current_date + time '00:30')::timestamptz, 'agent.orchestrator', 'zz-model-a', false, 0, 0, 0, 0, 1000000, 0, 200);

  SET LOCAL ROLE core_ro;
  r := core.fn_get_llm_cost_report(jsonb_build_object('chat_id', '7601', 'top_n', 2));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [Owner ok]: %', r; END IF;

  -- Summen 7 Tage: 4,60 + 0,50 + 0,12 + 0,006 + 10,00 = 15,226; 30 Tage + 1,00 = 16,226
  IF abs((r->'periods'->'d7'->>'total_usd')::numeric - 15.226) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Summe 7 T]: %', r->'periods'; END IF;
  IF abs((r->'periods'->'d30'->>'total_usd')::numeric - 16.226) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Summe 30 T]: %', r->'periods'; END IF;
  -- Abdeckung: data_since = heute-13 -> 7 von 7, 14 von 30 Tagen; Durchschnitte + Hochrechnung darauf
  IF (r->>'data_since')::date <> current_date - 13 THEN RAISE EXCEPTION 'FAIL [data_since]: %', r->>'data_since'; END IF;
  IF (r->'periods'->'d7'->>'days_covered')::int <> 7 OR (r->'periods'->'d30'->>'days_covered')::int <> 14 THEN
    RAISE EXCEPTION 'FAIL [days_covered]: %', r->'periods'; END IF;
  IF abs((r->'periods'->'d7'->>'avg_per_day_usd')::numeric - 15.226 / 7) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Schnitt 7 T]: %', r->'periods'; END IF;
  IF abs((r->'periods'->'d30'->>'projected_month_usd')::numeric - 16.226 / 14 * 30) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Hochrechnung]: %', r->'periods'; END IF;
  -- Vorwoche (heute-13 .. heute-7) voll abgedeckt: 1,00 -> +1423 %
  IF abs((r->'periods'->'d7'->>'prev_total_usd')::numeric - 1.0) > 0.0001 OR (r->'periods'->'d7'->>'change_pct')::int <> 1423 THEN
    RAISE EXCEPTION 'FAIL [Vorwoche]: %', r->'periods'; END IF;
  -- Anfragen (ohne Warmhalten) + ohne Preis
  IF (r->'periods'->'d7'->>'requests')::int <> 5 OR (r->'periods'->'d7'->>'unpriced_requests')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [Anfragen/ohne Preis]: %', r->'periods'; END IF;

  -- Kostenarten 7 Tage
  SELECT x INTO e FROM jsonb_array_elements(r->'kinds_d7') x WHERE x->>'kind' = 'input';
  IF abs((e->>'usd')::numeric - 1.006) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Input]: %', r->'kinds_d7'; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'kinds_d7') x WHERE x->>'kind' = 'cache_write';
  IF abs((e->>'usd')::numeric - 1.62) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Cache schreiben]: %', r->'kinds_d7'; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'kinds_d7') x WHERE x->>'kind' = 'cache_read';
  IF abs((e->>'usd')::numeric - 1.0) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Cache lesen]: %', r->'kinds_d7'; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'kinds_d7') x WHERE x->>'kind' = 'output';
  IF abs((e->>'usd')::numeric - 11.0) > 0.0001 OR (e->>'pct')::int <> 72 THEN RAISE EXCEPTION 'FAIL [Output + Anteil]: %', r->'kinds_d7'; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'kinds_d7') x WHERE x->>'kind' = 'web_search';
  IF abs((e->>'usd')::numeric - 0.1) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Websuche]: %', r->'kinds_d7'; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'kinds_d7') x WHERE x->>'kind' = 'keepalive';
  IF abs((e->>'usd')::numeric - 0.5) > 0.0001 THEN RAISE EXCEPTION 'FAIL [Warmhalten]: %', r->'kinds_d7'; END IF;
  IF (r->'kinds_d7'->0->>'kind') <> 'output' THEN RAISE EXCEPTION 'FAIL [Kostenarten absteigend]: %', r->'kinds_d7'; END IF;

  -- Workflows: Top 2 nach 30 Tagen (Orchestrator 10,00, Finanzen 5,22), Rest = Sonstige (Guide 1,00 + ohne wf 0,006)
  IF r->'by_workflow'->0->>'workflow' <> 'agent.orchestrator' OR r->'by_workflow'->1->>'workflow' <> 'agent.finance'
     OR abs((r->'by_workflow'->1->>'usd_d7')::numeric - 5.22) > 0.0001 THEN
    RAISE EXCEPTION 'FAIL [Top-Workflows]: %', r->'by_workflow'; END IF;
  e := r->'by_workflow'->2;
  IF (e->>'other')::boolean IS NOT TRUE OR e->'workflow' <> 'null'::jsonb
     OR abs((e->>'usd_d30')::numeric - 1.006) > 0.0001 OR abs((e->>'usd_d7')::numeric - 0.006) > 0.0001 THEN
    RAISE EXCEPTION 'FAIL [Sonstige]: %', r->'by_workflow'; END IF;
  IF jsonb_array_length(r->'by_workflow') <> 3 THEN RAISE EXCEPTION 'FAIL [Top-N + eine Sonstige-Zeile]: %', r->'by_workflow'; END IF;

  -- Modelle (nur bepreiste)
  SELECT x INTO e FROM jsonb_array_elements(r->'by_model') x WHERE x->>'model' = 'zz-model-a';
  IF abs((e->>'usd_d7')::numeric - 15.22) > 0.0001 OR abs((e->>'usd_d30')::numeric - 16.22) > 0.0001 THEN
    RAISE EXCEPTION 'FAIL [Modell a]: %', r->'by_model'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'by_model') x WHERE x->>'model' = 'unknown-model') THEN
    RAISE EXCEPTION 'FAIL [unbepreistes Modell nicht in der Modell-Liste]: %', r->'by_model'; END IF;

  -- Auffaelligkeiten: 2 Kaltstarts (r1 + r5) mit 1,62 Schreibkosten; teuerster Tag heute (Haushalts-TZ);
  -- Cache-Trefferquote 2 Mio / (1.002.000 + 530.000 + 2 Mio) = 57 %
  IF (r->'insights'->>'cold_starts_d7')::int <> 2 OR abs((r->'insights'->>'cold_start_usd_d7')::numeric - 1.62) > 0.0001 THEN
    RAISE EXCEPTION 'FAIL [Kaltstarts]: %', r->'insights'; END IF;
  IF (r->'insights'->>'top_day')::date <> current_date OR abs((r->'insights'->>'top_day_usd')::numeric - 15.226) > 0.0001 THEN
    RAISE EXCEPTION 'FAIL [teuerster Tag in Haushalts-TZ]: %', r->'insights'; END IF;
  IF (r->'insights'->>'cache_hit_pct_d7')::int <> 57 THEN RAISE EXCEPTION 'FAIL [Cache-Trefferquote]: %', r->'insights'; END IF;

  -- Kaltstart-Schwelle aus core.config: 40000 -> nur noch r1
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'cost', 'cold_start_min_tokens', '40000')
    ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;
  r := core.fn_get_llm_cost_report(jsonb_build_object('chat_id', '7601'));
  IF (r->'insights'->>'cold_starts_d7')::int <> 1 THEN RAISE EXCEPTION 'FAIL [Schwelle aus Config]: %', r->'insights'; END IF;
  -- Default top_n 5: alle drei Workflows + Sonstige (nur ohne-wf-Zeile)
  IF jsonb_array_length(r->'by_workflow') <> 4 THEN RAISE EXCEPTION 'FAIL [Default top_n]: %', r->'by_workflow'; END IF;

  -- Owner-Gate in der DB
  SET LOCAL ROLE core_ro;
  r := core.fn_get_llm_cost_report(jsonb_build_object('chat_id', '7602'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'owner_only' THEN RESET ROLE; RAISE EXCEPTION 'FAIL [Mitglied]: %', r; END IF;
  r := core.fn_get_llm_cost_report(jsonb_build_object('chat_id', '999999'));
  IF r->>'reason' <> 'owner_only' THEN RESET ROLE; RAISE EXCEPTION 'FAIL [unbekannt]: %', r; END IF;
  r := core.fn_get_llm_cost_report('{}'::jsonb);
  IF r->>'reason' <> 'owner_only' THEN RESET ROLE; RAISE EXCEPTION 'FAIL [ohne chat_id]: %', r; END IF;
  RESET ROLE;

  -- Leere Daten: ok, Summen 0, keine Abdeckung, keine Zeilen
  DELETE FROM core.llm_usage;
  r := core.fn_get_llm_cost_report(jsonb_build_object('chat_id', '7601'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->'periods'->'d7'->>'total_usd')::numeric <> 0 OR r->'data_since' <> 'null'::jsonb
     OR (r->'periods'->'d30'->>'days_covered')::int <> 0 OR r->'periods'->'d7'->'avg_per_day_usd' <> 'null'::jsonb
     OR jsonb_array_length(r->'by_workflow') <> 0 OR r->'insights'->'top_day' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [leer]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_get_llm_cost_report (Preis-Mathematik, Toepfe, Top-N, Vorwoche, Kaltstarts, TZ, Owner-Gate, core_ro)';
END $$;

ROLLBACK;
