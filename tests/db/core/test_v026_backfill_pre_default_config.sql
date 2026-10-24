-- tests/db/core/test_v026_backfill_pre_default_config.sql
-- core:V026: Releases bis v0.2.0 kannten core.config.default_value noch nicht -> Bestandszeilen haben default_value
-- NULL und gelten fuer core.fn_config_seed als "vom Owner gesetzt". V026 traegt fuer nie geaenderte Zeilen den
-- damals ausgelieferten Standard nach (Liste aller v0.2.0-Standards, Modelle nach der V024-Owner-Regel). Prueft
-- (ECHTE Datei, zweimal):
--   (1) panel_b sonnet + default NULL -> default_value = sonnet; der Seed setzt dann value = opus (der Fund)
--   (2) eine andere Listen-Zeile mit unveraendertem Wert (panel_a sonnet) wird ebenfalls nachgetragen (generisch)
--   (3) Owner-Wert (Wert != damaliger Standard) + default NULL -> unberuehrt; der Seed behaelt ihn
--   (4) Zeile ausserhalb der Liste + default NULL -> unberuehrt
--   (5) schon gesetzter default_value -> unberuehrt (nur die Vor-default-Aera)
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DELETE FROM core.config WHERE category = 'model' AND key IN ('panel_a', 'panel_b', 'guide');
INSERT INTO core.config (category, key, value, default_value, package) VALUES
  ('model',   'panel_b',        'claude-sonnet-latest', NULL, 'core'),   -- (1)
  ('model',   'panel_a',        'claude-sonnet-latest', NULL, 'core'),   -- (2)
  ('model',   'guide',          'claude-haiku-latest',  NULL, 'core'),   -- (3) v0.2.0-Standard war Sonnet (gemini-pro)
  ('general', '__t_v026_other', 'claude-sonnet-latest', NULL, 'core');   -- (4) nicht in der Liste

\ir ../../../packages/core/db/migrations/V026__backfill_pre_default_config.sql
\ir ../../../packages/core/db/migrations/V026__backfill_pre_default_config.sql

DO $$
BEGIN
  IF (SELECT default_value FROM core.config WHERE category = 'model' AND key = 'panel_b')
       IS DISTINCT FROM 'claude-sonnet-latest' THEN
    RAISE EXCEPTION 'FAIL (1) panel_b default_value nicht nachgetragen: %',
      (SELECT COALESCE(default_value, 'NULL') FROM core.config WHERE category = 'model' AND key = 'panel_b');
  END IF;
  PERFORM core.fn_config_seed(jsonb_build_object('category', 'model', 'key', 'panel_b',
                                                 'value', 'claude-opus-latest', 'package', 'core'));
  IF (SELECT value FROM core.config WHERE category = 'model' AND key = 'panel_b') <> 'claude-opus-latest' THEN
    RAISE EXCEPTION 'FAIL (1) Seed folgt dem neuen Standard nicht: %',
      (SELECT value FROM core.config WHERE category = 'model' AND key = 'panel_b');
  END IF;

  IF (SELECT default_value FROM core.config WHERE category = 'model' AND key = 'panel_a')
       IS DISTINCT FROM 'claude-sonnet-latest' THEN
    RAISE EXCEPTION 'FAIL (2) panel_a (unveraendert) nicht nachgetragen';
  END IF;

  IF (SELECT default_value FROM core.config WHERE category = 'model' AND key = 'guide') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (3) Owner-Wert-Zeile bekam einen nachgetragenen Standard';
  END IF;
  PERFORM core.fn_config_seed(jsonb_build_object('category', 'model', 'key', 'guide',
                                                 'value', 'claude-sonnet-latest', 'package', 'core'));
  IF (SELECT value FROM core.config WHERE category = 'model' AND key = 'guide') <> 'claude-haiku-latest' THEN
    RAISE EXCEPTION 'FAIL (3) Owner-Wert ueberschrieben';
  END IF;

  IF (SELECT default_value FROM core.config WHERE category = 'general' AND key = '__t_v026_other') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (4) Zeile ausserhalb der Liste angefasst';
  END IF;
END $$;

-- (5) default_value schon gesetzt (Instanz nach v0.2.0)
UPDATE core.config SET value = 'claude-sonnet-latest', default_value = 'claude-haiku-latest'
 WHERE category = 'model' AND key = 'panel_b';
\ir ../../../packages/core/db/migrations/V026__backfill_pre_default_config.sql
DO $$
BEGIN
  IF (SELECT default_value FROM core.config WHERE category = 'model' AND key = 'panel_b') <> 'claude-haiku-latest' THEN
    RAISE EXCEPTION 'FAIL (5) gesetzter default_value ueberschrieben';
  END IF;
  RAISE NOTICE 'PASS core:V026 (Vor-default-Aera generisch nachgetragen, Owner-Werte + spaetere Zeilen unberuehrt, 2 Laeufe)';
END $$;

ROLLBACK;
