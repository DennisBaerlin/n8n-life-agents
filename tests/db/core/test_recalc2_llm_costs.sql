-- tests/db/core/test_recalc2_llm_costs.sql
-- Zweitrechnung Runde 2, KI-Kosten (/costs, core.fn_get_llm_cost_report) mit den ECHTEN Seed-Preisen
-- (packages/core/seed/ai_models.json). Erwartungen von Hand gerechnet. Token-Zahlen erfunden.
-- Fachregel = offizielle Preisseite https://platform.claude.com/docs/en/about-claude/pricing (abgeglichen 2026-11-08):
--   Opus 5.5: 4 / 5 (Cache-Schreiben 5 Min) / 8 (1 h) / 0,20 (Lesen) / 20 (Output) USD je Mio Tokens;
--   Sonnet 5.5: 2 / 2,50 / 4 / 0,10 / 10; Haiku 5.5: 0,10 / 0,125 / 0,20 / 0,01 / 0,50, Prompt UEBER 100.000 Tokens
--   (input + Cache schreiben + Cache lesen) 0,50 / 0,625 / 1 / 0,05 / 2,50; Websuche 10 USD je 1.000 = 0,01 je Suche.
--   input_tokens ist der UNGECACHTE Rest (Gesamt-Eingabe = input + cache_creation + cache_read).
--   Zeilen heute:
--     A Opus: 12.000 in, Cache schreiben 30.000 (davon 1 h 25.000), lesen 400.000, out 2.500
--       = 0,048 + (0,025 + 0,200) + 0,080 + 0,050 = 0,403; Kaltstart (1 h >= 20.000), Kaltstart-Kosten 0,225.
--     B Haiku 110.000 Prompt (20.000 in + 90.000 lesen) > 100.000 -> Langkontext: 0,010 + 0,0045 + out 1.000 x 2,50 = 0,0025 -> 0,017.
--     B2 Haiku genau 100.000 (10.000 + 90.000) -> NICHT darueber: 0,001 + 0,0009 + 0,0005 = 0,0024.
--     C Sonnet: 5.000 in, 800 out, 3 Suchen = 0,010 + 0,008 + 0,030 = 0,048.
--     D Sonnet Warmhalten: 300.000 lesen = 0,030 -> Topf keepalive (keine Anfrage).
--     E unbekanntes Modell -> unbepreist, zaehlt als Anfrage, nicht in Summen.
--   Weitere: F vor 10 Tagen Sonnet 10.000 out = 0,10 (Vorwoche); G vor 20 Tagen Sonnet 5.000 out = 0,05.
--   (1) 7 Tage: 0,403 + 0,017 + 0,0024 + 0,048 + 0,030 = 0,5004; Anfragen 5 (A, B, B2, C, E), unbepreist 1;
--       Schnitt 0,5004 / 7 = 0,0715; Vorwoche 0,10 -> Veraenderung (0,5004 - 0,1) / 0,1 = +400 %.
--   (2) 30 Tage: 0,6504; Daten seit 20 Tagen -> 21 Tage -> Schnitt 0,0310, Hochrechnung 0,6504 / 21 x 30 = 0,9291.
--   (3) Arten 7 Tage: input 0,069; Cache schreiben 0,225; Cache lesen 0,0854; output 0,061; Websuche 0,030; keepalive 0,030.
--   (4) Cache-Trefferquote = gelesen / Gesamt-Eingabe der echten Anfragen = 580.000 / 1.657.000 = 35 %.
BEGIN;

SET LOCAL TimeZone = 'Europe/Berlin';

DO $$
DECLARE
  r jsonb; noon timestamptz := (current_date + time '12:00')::timestamptz;
BEGIN
  IF (SELECT pricing_usd_per_mtok->>'cache_read' FROM agent.ai_models WHERE n8n_model_id = 'claude-sonnet-5-5')::numeric IS DISTINCT FROM 0.10
     OR (SELECT pricing_usd_per_mtok->>'cache_read' FROM agent.ai_models WHERE n8n_model_id = 'claude-opus-5-5')::numeric IS DISTINCT FROM 0.20 THEN
    RAISE EXCEPTION 'FAIL [0] Seed-Preise weichen von der Preisseite ab'; END IF;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'recalc2 fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__r2c_owner__','first_name','Kim','last_name','Muster',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7701,'as_of','2026-10-25')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  DELETE FROM core.config WHERE category = 'cost' AND key = 'cold_start_min_tokens';
  DELETE FROM core.llm_usage;
  INSERT INTO core.llm_usage (id, ts, wf, model, keepalive, input_tokens, cache_creation_input_tokens,
                              ephemeral_1h_input_tokens, cache_read_input_tokens, output_tokens, web_search_requests, status) VALUES
    ('1000000000001-bbbbbb-000001', noon, 'agent.finance', 'claude-opus-5-5',   false, 12000, 30000, 25000, 400000, 2500, 0, 200),
    ('1000000000002-bbbbbb-000002', noon, 'agent.finance', 'claude-haiku-5-5',  false, 20000, 0, 0, 90000, 1000, 0, 200),
    ('1000000000003-bbbbbb-000003', noon, 'agent.finance', 'claude-haiku-5-5',  false, 10000, 0, 0, 90000, 1000, 0, 200),
    ('1000000000004-bbbbbb-000004', noon, 'agent.career',  'claude-sonnet-5-5', false, 5000, 0, 0, 0, 800, 3, 200),
    ('1000000000005-bbbbbb-000005', noon, NULL,            'claude-sonnet-5-5', true,  0, 0, 0, 300000, 0, 0, 200),
    ('1000000000006-bbbbbb-000006', noon, 'agent.finance', 'zz-unbekannt',      false, 1000000, 0, 0, 0, 0, 0, 200),
    ('1000000000007-bbbbbb-000007', noon - interval '10 days', 'agent.finance', 'claude-sonnet-5-5', false, 0, 0, 0, 0, 10000, 0, 200),
    ('1000000000008-bbbbbb-000008', noon - interval '20 days', 'agent.finance', 'claude-sonnet-5-5', false, 0, 0, 0, 0, 5000, 0, 200);

  r := core.fn_get_llm_cost_report('{"chat_id":"7701"}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [setup] %', r; END IF;
  IF (r->'periods'->'d7'->>'total_usd')::numeric IS DISTINCT FROM 0.5004
     OR (r->'periods'->'d7'->>'requests')::int IS DISTINCT FROM 5 OR (r->'periods'->'d7'->>'unpriced_requests')::int IS DISTINCT FROM 1
     OR (r->'periods'->'d7'->>'avg_per_day_usd')::numeric IS DISTINCT FROM 0.0715
     OR (r->'periods'->'d7'->>'prev_total_usd')::numeric IS DISTINCT FROM 0.1000
     OR (r->'periods'->'d7'->>'change_pct')::int IS DISTINCT FROM 400 THEN
    RAISE EXCEPTION 'FAIL [1] 7 Tage: %', r->'periods'->'d7'; END IF;
  RAISE NOTICE 'PASS [1] 7 Tage: 0,5004 USD, Langkontext-Grenze, Websuche, Warmhalten, Vorwoche';

  IF (r->'periods'->'d30'->>'total_usd')::numeric IS DISTINCT FROM 0.6504
     OR (r->'periods'->'d30'->>'days_covered')::int IS DISTINCT FROM 21
     OR (r->'periods'->'d30'->>'avg_per_day_usd')::numeric IS DISTINCT FROM 0.0310
     OR (r->'periods'->'d30'->>'projected_month_usd')::numeric IS DISTINCT FROM 0.9291 THEN
    RAISE EXCEPTION 'FAIL [2] 30 Tage: %', r->'periods'->'d30'; END IF;
  RAISE NOTICE 'PASS [2] 30 Tage: Schnitt ueber 21 abgedeckte Tage, Hochrechnung';

  IF EXISTS (SELECT 1 FROM (VALUES ('input', 0.069), ('cache_write', 0.225), ('cache_read', 0.0854), ('output', 0.061),
                                   ('web_search', 0.030), ('keepalive', 0.030)) e(kind, usd)
              WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'kinds_d7') k
                                 WHERE k->>'kind' = e.kind AND (k->>'usd')::numeric = e.usd)) THEN
    RAISE EXCEPTION 'FAIL [3] Arten: %', r->'kinds_d7'; END IF;
  RAISE NOTICE 'PASS [3] Kostenarten 7 Tage';

  IF (r->'insights'->>'cache_hit_pct_d7')::int IS DISTINCT FROM 35 OR (r->'insights'->>'cold_starts_d7')::int IS DISTINCT FROM 1
     OR (r->'insights'->>'cold_start_usd_d7')::numeric IS DISTINCT FROM 0.2250 THEN
    RAISE EXCEPTION 'FAIL [4] Kennzahlen: %', r->'insights'; END IF;
  RAISE NOTICE 'PASS [4] Cache-Trefferquote 35 %%, ein Kaltstart 0,225';
END $$;

ROLLBACK;
