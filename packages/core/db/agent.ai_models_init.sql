-- ============================================================
-- Agent AI-Models — Schema "agent", Registry-Tabelle "ai_models"
-- Zweck:   Wertevorrat ("Enum") der am Model Selector verdrahteten
--          LLMs. EINE Zeile je Modell, mit dem festen selector_index
--          (= physische Eingangs-Verdrahtung am modelSelector-Node).
--
-- Rolle im System:
--   * core.config (category='model') referenziert model_key dieser
--     Tabelle -> Fremdschluessel (core:V024, value + default_value, ON DELETE
--     RESTRICT) + Modell-Trigger in packages/core/db/core.config_init.sql.
--   * packages/core/seed/ai_models.json ist die Source of Truth der ZEILEN
--     (vom Installer seed_data.sh geseedet) UND zugleich die Build-Quelle der
--     Selector-Regeln (scripts/build/*) -> model_key<->selector_index
--     driftet nie zwischen DB und Workflow.
--
-- Diese Datei enthaelt nur das SCHEMA (leere Tabelle). Zeilen kommen
-- ausschliesslich per seed_data.sh aus packages/core/seed/ai_models.json.
--
-- Usage:   psql -U <user> -d <database> -f agent.ai_models_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

-- Namens-Vertrag (arch-challenge R3, Modell-Phase 1): model_key = Familien-Alias (z. B. 'claude-sonnet-latest'),
-- n8n_model_id = fest gepinnte Version (z. B. 'claude-sonnet-5-5'). "-latest" heisst "neueste vom Repo getestete
-- Generation" — die Version wechselt nur per Release (ai_models.json), nie still beim Anbieter.
CREATE TABLE IF NOT EXISTS agent.ai_models (
    model_key      varchar(64) PRIMARY KEY,            -- stabiler Familien-Alias, z. B. 'claude-sonnet-latest'
    provider       varchar(32)  NOT NULL,              -- 'Anthropic' (Chat) | 'Google' (nur Embeddings)
    n8n_model_id   varchar(128) NOT NULL,              -- gepinnte Version wie im LM-Node verdrahtet (z. B. 'claude-sonnet-5-5')
    selector_index int          UNIQUE                 -- modelIndex am Model Selector (1..numberInputs);
                       CHECK (selector_index >= 1),    --   NULL = Nicht-Selector-Modell (Embeddings, core:V017)
    mode           text         NOT NULL,              -- Modell-Art 'chat' | 'embedding' (CHECKs unten, core:V024)
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

-- Migration: tier-Spalte entfernen falls noch vorhanden (war rein deskriptiv, nicht mehr gebraucht)
ALTER TABLE agent.ai_models DROP COLUMN IF EXISTS tier;

-- mode (Modell-Phase 2, Muster LiteLLM `mode`): welche Art Modell eine Zeile ist. core.fn_model_value_eligible
-- (core.config_init.sql) laesst in einen Modell-Eintrag nur Modelle derselben Art wie sein Standard -> ein
-- Embedding-Modell landet nie am Chat-Umschalter. Bestands-DBs bekommen die Spalte hier leer (NULL besteht beide
-- CHECKs); core:V024 fuellt sie aus selector_index nach und setzt NOT NULL. Die CHECKs stehen benannt per
-- DROP/ADD hier (PG kennt kein ADD CONSTRAINT IF NOT EXISTS) — so laufen frische und Bestands-DB gleich.
ALTER TABLE agent.ai_models ADD COLUMN IF NOT EXISTS mode text;
ALTER TABLE agent.ai_models DROP CONSTRAINT IF EXISTS ai_models_mode_check;
ALTER TABLE agent.ai_models ADD CONSTRAINT ai_models_mode_check CHECK (mode IN ('chat', 'embedding'));
-- Chat-Modelle haengen am Umschalter (selector_index Pflicht), Embeddings nie.
ALTER TABLE agent.ai_models DROP CONSTRAINT IF EXISTS ai_models_mode_selector_check;
ALTER TABLE agent.ai_models ADD CONSTRAINT ai_models_mode_selector_check
    CHECK ((mode = 'chat') = (selector_index IS NOT NULL));

-- updated_at automatisch bei UPDATE pflegen
CREATE OR REPLACE FUNCTION agent.touch_ai_models_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ai_models_touch ON agent.ai_models;
CREATE TRIGGER trg_ai_models_touch
    BEFORE UPDATE ON agent.ai_models
    FOR EACH ROW EXECUTE FUNCTION agent.touch_ai_models_updated_at();
