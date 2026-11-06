-- tests/db/core/test_ai_models_pricing.sql
-- agent.ai_models.pricing_usd_per_mtok (Kosten-Report /kosten): CHECK ueber agent.fn_valid_model_pricing
--   (fuenf Pflicht-Preise als Zahl >= 0, optional long_context + web_search_usd_per_request), NULL = unbepreist erlaubt,
--   UNIQUE(n8n_model_id) (der Report bepreist ueber diese Spalte), und der Seed (ai_models.json) traegt fuer jedes
--   Chat-Modell gueltige Preise.
BEGIN;

DO $$
DECLARE v_n int;
BEGIN
  -- gueltig: Pflicht-Preise + optionale Teile; NULL erlaubt
  INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode, pricing_usd_per_mtok) VALUES
    ('zz-pr-ok', 'Anthropic', 'zz-pr-ok', NULL, 'embedding',
     '{"_source":"x","input":1,"cache_write_5m":1.25,"cache_write_1h":2,"cache_read":0.1,"output":5,"web_search_usd_per_request":0.01,
       "long_context":{"above_input_tokens":100000,"input":2,"cache_write_5m":2.5,"cache_write_1h":4,"cache_read":0.2,"output":10}}'),
    ('zz-pr-null', 'Google', 'zz-pr-null', NULL, 'embedding', NULL);

  -- ungueltig: negativ, Schluessel fehlt, String statt Zahl, kaputtes long_context, negativer Websuche-Preis, kein Objekt
  DECLARE bad jsonb;
  BEGIN
    FOREACH bad IN ARRAY ARRAY[
      '{"input":-1,"cache_write_5m":1,"cache_write_1h":1,"cache_read":1,"output":1}'::jsonb,
      '{"input":1,"cache_write_5m":1,"cache_write_1h":1,"cache_read":1}'::jsonb,
      '{"input":"1","cache_write_5m":1,"cache_write_1h":1,"cache_read":1,"output":1}'::jsonb,
      '{"input":1,"cache_write_5m":1,"cache_write_1h":1,"cache_read":1,"output":1,"long_context":{"input":1}}'::jsonb,
      '{"input":1,"cache_write_5m":1,"cache_write_1h":1,"cache_read":1,"output":1,"web_search_usd_per_request":-0.01}'::jsonb,
      '[1,2]'::jsonb,
      'null'::jsonb] LOOP
      BEGIN
        INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode, pricing_usd_per_mtok)
        VALUES ('zz-pr-bad', 'Anthropic', 'zz-pr-bad', NULL, 'embedding', bad);
        RAISE EXCEPTION 'FAIL [ungueltige Preise angenommen]: %', bad;
      EXCEPTION WHEN check_violation THEN NULL;
      END;
    END LOOP;
  END;

  -- UNIQUE(n8n_model_id)
  BEGIN
    INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode) VALUES ('zz-pr-dup', 'Anthropic', 'zz-pr-ok', NULL, 'embedding');
    RAISE EXCEPTION 'FAIL [doppelte n8n_model_id angenommen]';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- Seed: jedes Chat-Modell traegt Preise (sonst zeigte /kosten alles als "ohne Preis")
  SELECT count(*) INTO v_n FROM agent.ai_models WHERE mode = 'chat' AND pricing_usd_per_mtok IS NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [Chat-Modell ohne Preis im Seed]: %', v_n; END IF;
  SELECT count(*) INTO v_n FROM agent.ai_models WHERE mode = 'chat';
  IF v_n = 0 THEN RAISE EXCEPTION 'FAIL [Seed fehlt: keine Chat-Modelle]'; END IF;

  RAISE NOTICE 'PASS test_ai_models_pricing (Form-CHECK, NULL erlaubt, UNIQUE n8n_model_id, Seed bepreist)';
END $$;

ROLLBACK;
