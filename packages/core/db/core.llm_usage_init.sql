-- ============================================================
-- core.llm_usage — Mitschrift der Claude-Nutzung (Kosten-Report /kosten)
-- Zweck:   je Anfrage durch den lokalen LLM-Gateway (provisioning/llm_gateway) EINE Zeile mit den rohen
--          Anthropic-usage-Zahlen + dem ausloesenden Workflow. Quelle ist die Gateway-Datei usage.jsonl, die der
--          /kosten-Sub per GET /__usage holt und ueber core.fn_import_llm_usage einspielt (idempotent ueber id).
--          Kosten sind bewusst KEINE Spalte (abgeleitet aus agent.ai_models.pricing_usd_per_mtok, Preise koennen sich
--          aendern) -> core.fn_get_llm_cost_report rechnet sie beim Lesen.
-- Privacy: nur Zahlen, Modell, Workflow-Name und Zeit — nie Prompt-, Antwort- oder Header-Inhalte.
-- Retention: 13 Monate, aufgeraeumt inline beim Import (kein Cron).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.llm_usage (
    -- Gateway-id = Schluessel fuer Idempotenz + Abruf-Reihenfolge: 13-stellige Epoch-ms + Prozess-Kennung (6 hex) +
    -- Zaehler (sortierbar, eindeutig ueber Neustarts; der Gateway schreibt ms-Praefix und t aus derselben Uhr). Die DB
    -- liest die Zeit nur aus ts, nie aus der id (Ausnahme (c) sql.md: Provenienz-Schluessel der Quelle).
    id                          text PRIMARY KEY CHECK (id ~ '^[0-9]{13}-[0-9a-f]{6}-[0-9]{6}$'),
    ts                          timestamptz NOT NULL,                       -- Zeitpunkt der Anfrage (Gateway-Uhr)
    wf                          text CHECK (wf IS NULL OR wf ~ '^[a-z0-9._-]{1,80}$'),   -- ausloesender Workflow; NULL = nicht zugeordnet
    model                       text,                                       -- Anthropic-Modell-id der Anfrage (= agent.ai_models.n8n_model_id)
    keepalive                   boolean NOT NULL DEFAULT FALSE,             -- Warmhalte-Anstupser des Gateways (max_tokens 0)
    status                      int,                                        -- HTTP-Status der Antwort
    -- Anthropic-Feldnamen: input_tokens = UNGECACHTER Rest; Gesamt-Eingabe = input + cache_creation + cache_read
    input_tokens                bigint NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    cache_creation_input_tokens bigint NOT NULL DEFAULT 0 CHECK (cache_creation_input_tokens >= 0),
    ephemeral_1h_input_tokens   bigint NOT NULL DEFAULT 0 CHECK (ephemeral_1h_input_tokens >= 0),   -- Anteil 1h-TTL (Rest = 5 Min)
    cache_read_input_tokens     bigint NOT NULL DEFAULT 0 CHECK (cache_read_input_tokens >= 0),
    output_tokens               bigint NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
    web_search_requests         int    NOT NULL DEFAULT 0 CHECK (web_search_requests >= 0),
    imported_at                 timestamptz NOT NULL DEFAULT now()          -- Provenienz: wann eingespielt
);

CREATE INDEX IF NOT EXISTS llm_usage_ts_idx ON core.llm_usage (ts);
