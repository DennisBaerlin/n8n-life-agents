-- tests/db/core/test_core_config.sql
-- Testet core.config:
--   (1) UNIQUE(category,key) blockt Dubletten.
--   (2) Integritaets-Trigger: category='model' mit unbekanntem value wird abgelehnt,
--       mit bekanntem model_key (aus agent.ai_models) akzeptiert.
--   (3) Nicht-model-Kategorien (z. B. transcription) sind frei (kein Enum-Zwang).
-- Hinweis: der updated_at-Touch-Trigger ist NICHT testbar in einer einzelnen Transaktion
--   (NOW() = transaction_timestamp, also konstant von BEGIN bis ROLLBACK) -> hier weggelassen.
-- Pattern: BEGIN…ROLLBACK, erwartete Blockaden in inneren BEGIN/EXCEPTION-Bloecken.
BEGIN;

DO $$
DECLARE
  v_blocked BOOLEAN;
BEGIN
  -- Setup: ein bekanntes Modell in der Registry (im Prod via JSON-Push geseedet)
  INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode)
  VALUES ('__test_model__', 'Anthropic', '__test_model__', 99, 'chat');

  -- (1) gueltige model-Zeile mit bekanntem model_key -> akzeptiert
  INSERT INTO core.config (category, key, value)
  VALUES ('model', '__test_consumer__', '__test_model__');

  -- (2) Dublette (category,key) -> UNIQUE blockt
  v_blocked := FALSE;
  BEGIN
    INSERT INTO core.config (category, key, value)
    VALUES ('model', '__test_consumer__', '__test_model__');
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL core.config: UNIQUE(category,key) nicht durchgesetzt'; END IF;

  -- (3) model mit UNBEKANNTEM value -> Integritaets-Trigger blockt
  v_blocked := FALSE;
  BEGIN
    INSERT INTO core.config (category, key, value)
    VALUES ('model', '__test_consumer2__', '__does_not_exist__');
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL core.config: unbekannter model_key wurde NICHT blockiert'; END IF;

  -- (4) Nicht-model-Kategorie ist frei (kein Enum-Zwang)
  INSERT INTO core.config (category, key, value)
  VALUES ('transcription', '__test_provider__', 'groq');

  -- (5) UPDATE auf einen unbekannten model_key -> ebenfalls blockiert (Trigger auch BEFORE UPDATE)
  v_blocked := FALSE;
  BEGIN
    UPDATE core.config SET value = '__nope__'
    WHERE category = 'model' AND key = '__test_consumer__';
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL core.config: UPDATE auf unbekannten model_key nicht blockiert'; END IF;

  -- (6) gueltiges UPDATE einer freien Kategorie wird akzeptiert
  UPDATE core.config SET value = 'google' WHERE category = 'transcription' AND key = '__test_provider__';

  RAISE NOTICE 'PASS core.config: UNIQUE + Modell-Enum-Trigger (INSERT/UPDATE) + freie Kategorie';
END $$;

ROLLBACK;
