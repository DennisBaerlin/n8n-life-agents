-- ============================================================
-- core.v_llm_usage_cost — je Zeile der Gateway-Mitschrift die Kosten in USD (eine Adresse der Preisformel)
--   Quelle core.llm_usage x agent.ai_models.pricing_usd_per_mtok (model = n8n_model_id, aktuelle Preisliste):
--     c_input = input_tokens x input; c_write = (cache_creation - ephemeral_1h) x cache_write_5m + ephemeral_1h x
--     cache_write_1h; c_read = cache_read x cache_read; c_output = output x output; c_web = web_search_requests x
--     web_search_usd_per_request; usd = Summe. Langkontext-Stufe: liegt die Gesamt-Eingabe (input + cache_creation +
--     cache_read) ueber long_context.above_input_tokens, gelten die long_context-Preise (Websuche bleibt).
--   unpriced = Modell nicht im Register (alle Kosten 0, zaehlt nicht in Summen).
--   Leser: core.fn_get_llm_cost_report (/kosten), core.fn_llm_incident_note (Verbrauch im Monat auf der Pause-Karte).
--   Tests: tests/db/core/test_fn_get_llm_cost_report.sql, tests/db/core/test_fn_llm_incident_note.sql
-- ============================================================
CREATE OR REPLACE VIEW core.v_llm_usage_cost AS
SELECT c.*, c.c_input + c.c_write + c.c_read + c.c_output + c.c_web AS usd
  FROM (SELECT px.id, px.ts, px.wf, px.model, px.keepalive, px.status, px.err_code,
               px.input_tokens, px.cache_creation_input_tokens, px.ephemeral_1h_input_tokens, px.cache_read_input_tokens,
               px.output_tokens, px.web_search_requests,
               px.pr IS NULL AS unpriced,
               coalesce(px.input_tokens * (px.t->>'input')::numeric / 1e6, 0) AS c_input,
               coalesce((greatest(px.cache_creation_input_tokens - px.ephemeral_1h_input_tokens, 0) * (px.t->>'cache_write_5m')::numeric
                         + px.ephemeral_1h_input_tokens * (px.t->>'cache_write_1h')::numeric) / 1e6, 0) AS c_write,
               coalesce(px.cache_read_input_tokens * (px.t->>'cache_read')::numeric / 1e6, 0) AS c_read,
               coalesce(px.output_tokens * (px.t->>'output')::numeric / 1e6, 0) AS c_output,
               coalesce(px.web_search_requests * (px.pr->>'web_search_usd_per_request')::numeric, 0) AS c_web
          FROM (SELECT u.*, m.pricing_usd_per_mtok AS pr,
                       CASE WHEN m.pricing_usd_per_mtok ? 'long_context'
                             AND (u.input_tokens + u.cache_creation_input_tokens + u.cache_read_input_tokens)
                                 > (m.pricing_usd_per_mtok->'long_context'->>'above_input_tokens')::numeric
                            THEN m.pricing_usd_per_mtok->'long_context' ELSE m.pricing_usd_per_mtok END AS t
                  FROM core.llm_usage u
                  LEFT JOIN agent.ai_models m ON m.n8n_model_id = u.model) px) c;
