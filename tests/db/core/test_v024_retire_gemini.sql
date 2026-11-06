-- tests/db/core/test_v024_retire_gemini.sql
-- Modell-Phase 2: core:V024 stellt eine Bestands-Installation von Gemini auf Claude um. Der Test baut den
-- Zustand VOR V024 nach (ohne Fremdschluessel, mode teils leer, die 3 Gemini-Chat-Zeilen + Config-Zeilen aller
-- Faelle), fuehrt die ECHTE Migrationsdatei zweimal aus (\ir, keine Kopie -> kein Drift; 2. Lauf = No-op) und prueft:
--   (1) Owner-Regel: gemini-2.5-flash -> claude-haiku-latest, jedes andere Gemini-Chat-Modell -> claude-sonnet-latest
--       (value UND default_value; auch Zeilen nicht installierter Pakete)
--   (2) ein Owner-Wert, der schon auf Claude steht, bleibt
--   (3) Altlasten: verwaister Wert oder Wert falscher Art (Embedding) -> gueltiger Standard bzw. claude-sonnet-latest;
--       verwaister Standard -> NULL
--   (4) die Gemini-Chat-Zeilen sind weg, das Embedding-Modell bleibt; mode ist nachgefuellt + NOT NULL
--   (5) Fremdschluessel: ein von value ODER default_value genutztes Modell ist nicht loeschbar
--   (6) Nicht-Modell-Config ist unberuehrt
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

-- ---------- Zustand vor V024 nachbauen ----------
ALTER TABLE core.config DROP CONSTRAINT IF EXISTS config_model_ref_fkey;
ALTER TABLE core.config DROP CONSTRAINT IF EXISTS config_model_default_ref_fkey;
ALTER TABLE agent.ai_models ALTER COLUMN mode DROP NOT NULL;
ALTER TABLE core.config DISABLE TRIGGER trg_config_check_model_value;   -- Altbestand darf "kaputt" sein

INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode) VALUES
  ('gemini-2.5-flash',  'Google', 'models/gemini-2.5-flash',  91, 'chat'),
  ('gemini-3.5-flash',  'Google', 'models/gemini-3.5-flash',  93, NULL),     -- mode noch leer (vor dem Nachfuellen)
  ('gemini-pro-latest', 'Google', 'models/gemini-pro-latest', 95, 'chat'),
  ('__t_legacy_emb',    'Google', 'models/e',                 NULL, NULL),
  ('__t_defonly',       'Anthropic', 'x',                     96, 'chat')
ON CONFLICT (model_key) DO UPDATE SET selector_index = excluded.selector_index, mode = excluded.mode;

INSERT INTO core.config (category, key, value, default_value, package) VALUES
  ('model',   '__t_alt_flash', 'gemini-2.5-flash',   'gemini-2.5-flash',    '__tpkg'),
  ('model',   '__t_alt_pro',   'gemini-pro-latest',  'gemini-pro-latest',   '__tpkg'),
  ('model',   '__t_ovr_pro',   'gemini-pro-latest',  'claude-haiku-latest', '__tpkg'),
  ('model',   '__t_ovr_claude','claude-opus-latest', 'gemini-3.5-flash',    '__tpkg'),
  ('model',   '__t_gone_pkg',  'gemini-3.5-flash',   'gemini-3.5-flash',    '__tgone'),
  ('model',   '__t_orphan_nd', '__t_never_there',    NULL,                  '__tpkg'),
  ('model',   '__t_orphan_d',  '__t_never_there',    'claude-haiku-latest', '__tpkg'),
  ('model',   '__t_orphan_def','claude-opus-latest', '__t_never_there',     '__tpkg'),
  ('model',   '__t_defonly_u', 'claude-haiku-latest','__t_defonly',         '__tpkg'),
  ('model',   '__t_emb_val',   '__t_legacy_emb',     'gemini-pro-latest',   '__tpkg'),   -- Wert falscher Art (alte CLI-Auswahl)
  ('general', '__t_free',      'gemini-2.5-flash',   'gemini-2.5-flash',    '__tpkg');

ALTER TABLE core.config ENABLE TRIGGER trg_config_check_model_value;

-- ---------- die ECHTE Migration (zweimal: Idempotenz) ----------
\ir ../../../packages/core/db/migrations/V024__retire_gemini_chat_models.sql
\ir ../../../packages/core/db/migrations/V024__retire_gemini_chat_models.sql

DO $$
DECLARE
  v_blocked boolean;
  r record;
BEGIN
  -- (1)-(3) erwartete Werte je Zeile
  FOR r IN
    SELECT * FROM (VALUES
      ('__t_alt_flash',  'claude-haiku-latest',  'claude-haiku-latest'),
      ('__t_alt_pro',    'claude-sonnet-latest', 'claude-sonnet-latest'),
      ('__t_ovr_pro',    'claude-sonnet-latest', 'claude-haiku-latest'),
      ('__t_ovr_claude', 'claude-opus-latest',   'claude-sonnet-latest'),
      ('__t_gone_pkg',   'claude-sonnet-latest', 'claude-sonnet-latest'),
      ('__t_orphan_nd',  'claude-sonnet-latest', NULL),
      ('__t_orphan_d',   'claude-haiku-latest',  'claude-haiku-latest'),
      ('__t_orphan_def', 'claude-opus-latest',   NULL),
      ('__t_emb_val',    'claude-sonnet-latest', 'claude-sonnet-latest')
    ) AS e(k, want_value, want_default)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM core.config c WHERE c.category = 'model' AND c.key = r.k
                     AND c.value = r.want_value AND c.default_value IS NOT DISTINCT FROM r.want_default) THEN
      RAISE EXCEPTION 'FAIL (1-3) %: erwartet value=% default=%, ist %', r.k, r.want_value, r.want_default,
        (SELECT value || ' / ' || COALESCE(default_value, 'NULL') FROM core.config WHERE category = 'model' AND key = r.k);
    END IF;
  END LOOP;

  -- (4) Register
  IF EXISTS (SELECT 1 FROM agent.ai_models WHERE provider = 'Google' AND mode = 'chat') THEN
    RAISE EXCEPTION 'FAIL (4) Gemini-Chat-Zeilen noch da: %',
      (SELECT string_agg(model_key, ', ') FROM agent.ai_models WHERE provider = 'Google' AND mode = 'chat');
  END IF;
  IF (SELECT mode FROM agent.ai_models WHERE model_key = '__t_legacy_emb') IS DISTINCT FROM 'embedding' THEN
    RAISE EXCEPTION 'FAIL (4) mode nicht aus selector_index nachgefuellt';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.ai_models WHERE mode IS NULL)
     OR NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'agent.ai_models'::regclass AND attname = 'mode') THEN
    RAISE EXCEPTION 'FAIL (4) mode nicht NOT NULL';
  END IF;

  -- (5) Fremdschluessel (value und default_value)
  v_blocked := false;
  BEGIN
    DELETE FROM agent.ai_models WHERE model_key = 'claude-haiku-latest';
  EXCEPTION WHEN foreign_key_violation THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL (5) per value referenziertes Modell loeschbar'; END IF;
  v_blocked := false;
  BEGIN
    DELETE FROM agent.ai_models WHERE model_key = '__t_defonly';
  EXCEPTION WHEN foreign_key_violation THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL (5) per default_value referenziertes Modell loeschbar'; END IF;

  -- (6) Nicht-Modell-Config unberuehrt
  IF (SELECT value FROM core.config WHERE category = 'general' AND key = '__t_free') <> 'gemini-2.5-flash' THEN
    RAISE EXCEPTION 'FAIL (6) Nicht-Modell-Config umgeschrieben';
  END IF;

  RAISE NOTICE 'PASS core:V024 (Owner-Regel, Altlasten, Register, FK, 2 Laeufe)';
END $$;

ROLLBACK;
