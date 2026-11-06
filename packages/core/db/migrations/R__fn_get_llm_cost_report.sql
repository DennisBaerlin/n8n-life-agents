-- ============================================================
-- core.fn_get_llm_cost_report(p) — das Datenmodell von /costs (/kosten): KI-Kosten der letzten 7 und 30 Tage
--   p: { chat_id, top_n? (1..10, Default 5) }
--   Quelle core.llm_usage (Gateway-Mitschrift) x agent.ai_models.pricing_usd_per_mtok (USD je Mio Tokens), bepreist
--   ueber model = n8n_model_id mit der AKTUELLEN Preisliste. Je Zeile:
--     input        = input_tokens x input
--     cache_write  = (cache_creation - ephemeral_1h) x cache_write_5m + ephemeral_1h x cache_write_1h
--     cache_read   = cache_read x cache_read;  output = output x output
--     web_search   = web_search_requests x web_search_usd_per_request
--   Langkontext-Stufe: liegt die Gesamt-Eingabe (input + cache_creation + cache_read) ueber long_context.
--   above_input_tokens, gelten die long_context-Preise (Websuche bleibt). Warmhalte-Zeilen (keepalive) zaehlen ganz
--   in den Topf keepalive. Zeilen ohne Preis (Modell nicht im Register) zaehlen nicht in Summen, nur als
--   unpriced_requests.
--   Tage = Kalendertage in der Sitzungs-Zeitzone (= Haushalts-Zeitzone, provisioning): d7 = heute + 6 Tage zurueck,
--   d30 = heute + 29 zurueck, Vorwoche = heute-13 .. heute-7 (nur wenn die Daten so weit zurueckreichen).
--   days_covered = Tage seit der fruehesten Zeile (max. Fensterlaenge) -> Schnitt und Hochrechnung (x 30) ehrlich,
--   solange die Mitschrift juenger als das Fenster ist.
--   Kaltstart = echte Anfrage mit 1h-Cache-Write >= core.config cost.cold_start_min_tokens (Default 20000):
--   ein grosser Agenten-Anfang wurde neu geschrieben (Update, > 24 h Pause).
--   Cache-Trefferquote = Cache-Lesen / Gesamt-Eingabe der echten Anfragen (7 Tage), ganze Prozent.
--   Owner-Gate (DB-Gesetz): Absender aus chat_id via agent.fn_resolve_sender; nicht Owner -> {ok:false, reason:'owner_only'}.
--   RUECKGABE: {ok:true, today, data_since, top_n,
--     periods: { d7: {total_usd, avg_per_day_usd, days_covered, requests, unpriced_requests, prev_total_usd, change_pct},
--                d30: {total_usd, avg_per_day_usd, days_covered, requests, unpriced_requests, projected_month_usd} },
--     kinds_d7: [{kind, usd, pct}] absteigend (input|cache_write|cache_read|output|web_search|keepalive),
--     by_workflow: [{workflow, usd_d7, usd_d30}] Top-N nach 30 Tagen + hoechstens eine {workflow:null, other:true, ...},
--     by_model: [{model, usd_d7, usd_d30}] absteigend (nur bepreiste),
--     insights: {cold_starts_d7, cold_start_usd_d7, top_day, top_day_usd, cache_hit_pct_d7} }
--   Betraege auf 4 Nachkommastellen gerundet; die Anzeige formatiert nur.
--   D10 / Auth: SECURITY DEFINER (der /kosten-Sub liest unter core_ro), search_path gepinnt, alles voll-qualifiziert,
--   kein dynamisches SQL. EXECUTE nur an core_ro (util_create_core_ro.sql).
--   Tests: tests/db/core/test_fn_get_llm_cost_report.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_get_llm_cost_report(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat    text := NULLIF(trim(p->>'chat_id'), '');
    v_top     int  := CASE WHEN COALESCE(p->>'top_n', '') ~ '^[0-9]{1,2}$'
                           THEN LEAST(GREATEST((p->>'top_n')::int, 1), 10) ELSE 5 END;
    v_sender  jsonb;
    v_today   date := current_date;
    v_cold    bigint;
    v_since   date;
    v_cov7    int;
    v_cov30   int;
    v_res     jsonb;
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(v_chat::bigint);
    END IF;
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE OR v_sender->>'role' IS DISTINCT FROM 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;

    v_cold := COALESCE(NULLIF(core.fn_config_get('core', 'cost', 'cold_start_min_tokens'), '')::bigint, 20000);
    SELECT min(u.ts)::date INTO v_since FROM core.llm_usage u;
    v_cov7  := CASE WHEN v_since IS NULL THEN 0 ELSE LEAST(7,  v_today - v_since + 1) END;
    v_cov30 := CASE WHEN v_since IS NULL THEN 0 ELSE LEAST(30, v_today - v_since + 1) END;

    WITH r AS (
        SELECT u.*, u.ts::date AS d, m.pricing_usd_per_mtok AS pr
          FROM core.llm_usage u
          LEFT JOIN agent.ai_models m ON m.n8n_model_id = u.model
         -- Fenster als timestamptz-Bereich (Tagesgrenzen in der Sitzungs-Zeitzone) -> nutzt llm_usage_ts_idx
         WHERE u.ts >= (v_today - 29)::timestamptz AND u.ts < (v_today + 1)::timestamptz
    ), px AS (
        SELECT r.*,
               CASE WHEN r.pr ? 'long_context'
                     AND (r.input_tokens + r.cache_creation_input_tokens + r.cache_read_input_tokens)
                         > (r.pr->'long_context'->>'above_input_tokens')::numeric
                    THEN r.pr->'long_context' ELSE r.pr END AS t
          FROM r
    ), c AS (
        SELECT px.d, px.wf, px.model, px.keepalive, px.pr IS NULL AS unpriced,
               px.d >= v_today - 6 AS in7,
               px.input_tokens, px.cache_creation_input_tokens, px.ephemeral_1h_input_tokens, px.cache_read_input_tokens,
               COALESCE(px.input_tokens * (px.t->>'input')::numeric / 1e6, 0) AS c_input,
               COALESCE((GREATEST(px.cache_creation_input_tokens - px.ephemeral_1h_input_tokens, 0) * (px.t->>'cache_write_5m')::numeric
                         + px.ephemeral_1h_input_tokens * (px.t->>'cache_write_1h')::numeric) / 1e6, 0) AS c_write,
               COALESCE(px.cache_read_input_tokens * (px.t->>'cache_read')::numeric / 1e6, 0) AS c_read,
               COALESCE(px.output_tokens * (px.t->>'output')::numeric / 1e6, 0) AS c_output,
               COALESCE(px.web_search_requests * (px.pr->>'web_search_usd_per_request')::numeric, 0) AS c_web
          FROM px
    ), k AS (
        SELECT c.*, c.c_input + c.c_write + c.c_read + c.c_output + c.c_web AS c_total FROM c
    ), w7 AS (
        SELECT COALESCE(sum(c_total), 0) AS total,
               count(*) FILTER (WHERE NOT keepalive) AS requests,
               count(*) FILTER (WHERE unpriced) AS unpriced,
               COALESCE(sum(c_input)  FILTER (WHERE NOT keepalive), 0) AS k_input,
               COALESCE(sum(c_write)  FILTER (WHERE NOT keepalive), 0) AS k_write,
               COALESCE(sum(c_read)   FILTER (WHERE NOT keepalive), 0) AS k_read,
               COALESCE(sum(c_output) FILTER (WHERE NOT keepalive), 0) AS k_output,
               COALESCE(sum(c_web)    FILTER (WHERE NOT keepalive), 0) AS k_web,
               COALESCE(sum(c_total)  FILTER (WHERE keepalive), 0) AS k_keepalive,
               count(*) FILTER (WHERE NOT keepalive AND ephemeral_1h_input_tokens >= v_cold) AS cold_n,
               COALESCE(sum(c_write) FILTER (WHERE NOT keepalive AND ephemeral_1h_input_tokens >= v_cold), 0) AS cold_usd,
               COALESCE(sum(cache_read_input_tokens) FILTER (WHERE NOT keepalive), 0) AS tok_read,
               COALESCE(sum(input_tokens + cache_creation_input_tokens + cache_read_input_tokens) FILTER (WHERE NOT keepalive), 0) AS tok_in
          FROM k WHERE in7
    ), w30 AS (
        SELECT COALESCE(sum(c_total), 0) AS total,
               count(*) FILTER (WHERE NOT keepalive) AS requests,
               count(*) FILTER (WHERE unpriced) AS unpriced
          FROM k
    ), prev AS (
        SELECT COALESCE(sum(c_total), 0) AS total FROM k WHERE d BETWEEN v_today - 13 AND v_today - 7
    ), kinds AS (
        SELECT kind, usd FROM w7,
               LATERAL (VALUES ('input', k_input), ('cache_write', k_write), ('cache_read', k_read),
                               ('output', k_output), ('web_search', k_web), ('keepalive', k_keepalive)) v(kind, usd)
    ), per_wf AS (
        SELECT k.wf,
               COALESCE(sum(k.c_total) FILTER (WHERE k.in7), 0) AS usd7,
               COALESCE(sum(k.c_total), 0) AS usd30
          FROM k WHERE NOT k.unpriced GROUP BY k.wf
    ), wf_ranked AS (
        -- Rang nach 30 Tagen; ohne Workflow immer zuletzt (landet in Sonstige)
        SELECT p.wf, p.usd7, p.usd30, row_number() OVER (ORDER BY (p.wf IS NULL), p.usd30 DESC, p.wf) AS rn FROM per_wf p
    ), mdl AS (
        SELECT model,
               COALESCE(sum(c_total) FILTER (WHERE in7), 0) AS usd7,
               COALESCE(sum(c_total), 0) AS usd30
          FROM k WHERE NOT unpriced GROUP BY model
    ), days AS (
        SELECT d, sum(c_total) AS usd FROM k WHERE in7 GROUP BY d ORDER BY sum(c_total) DESC, d DESC LIMIT 1
    )
    SELECT jsonb_build_object(
        'ok', true,
        'today', v_today,
        'data_since', v_since,
        'top_n', v_top,
        'periods', jsonb_build_object(
            'd7', jsonb_build_object(
                'total_usd', round(w7.total, 4),
                'avg_per_day_usd', CASE WHEN v_cov7 > 0 THEN round(w7.total / v_cov7, 4) END,
                'days_covered', v_cov7,
                'requests', w7.requests,
                'unpriced_requests', w7.unpriced,
                'prev_total_usd', CASE WHEN v_since <= v_today - 13 THEN round(prev.total, 4) END,
                'change_pct', CASE WHEN v_since <= v_today - 13 AND prev.total > 0
                                   THEN round((w7.total - prev.total) / prev.total * 100)::int END),
            'd30', jsonb_build_object(
                'total_usd', round(w30.total, 4),
                'avg_per_day_usd', CASE WHEN v_cov30 > 0 THEN round(w30.total / v_cov30, 4) END,
                'days_covered', v_cov30,
                'requests', w30.requests,
                'unpriced_requests', w30.unpriced,
                'projected_month_usd', CASE WHEN v_cov30 > 0 THEN round(w30.total / v_cov30 * 30, 4) END)),
        'kinds_d7', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                  'kind', kind, 'usd', round(usd, 4),
                                  'pct', CASE WHEN w7.total > 0 THEN round(usd / w7.total * 100)::int ELSE 0 END)
                                ORDER BY usd DESC, kind) FROM kinds), '[]'::jsonb),
        'by_workflow', COALESCE((SELECT jsonb_agg(x ORDER BY o) FROM (
                SELECT rn AS o, jsonb_build_object('workflow', wf, 'usd_d7', round(usd7, 4), 'usd_d30', round(usd30, 4)) AS x
                  FROM wf_ranked WHERE rn <= v_top AND wf IS NOT NULL
                UNION ALL
                SELECT 999, jsonb_build_object('workflow', NULL, 'other', true,
                                               'usd_d7', round(sum(usd7), 4), 'usd_d30', round(sum(usd30), 4))
                  FROM wf_ranked WHERE rn > v_top OR wf IS NULL
                HAVING count(*) > 0) s), '[]'::jsonb),
        'by_model', COALESCE((SELECT jsonb_agg(jsonb_build_object('model', model, 'usd_d7', round(usd7, 4), 'usd_d30', round(usd30, 4))
                                ORDER BY usd30 DESC, model) FROM mdl), '[]'::jsonb),
        'insights', jsonb_build_object(
            'cold_starts_d7', w7.cold_n,
            'cold_start_usd_d7', round(w7.cold_usd, 4),
            'top_day', (SELECT d FROM days),
            'top_day_usd', (SELECT round(usd, 4) FROM days),
            'cache_hit_pct_d7', CASE WHEN w7.tok_in > 0 THEN round(w7.tok_read::numeric / w7.tok_in * 100)::int END))
      INTO v_res
      FROM w7, w30, prev;

    RETURN v_res;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_get_llm_cost_report(jsonb) FROM public;
