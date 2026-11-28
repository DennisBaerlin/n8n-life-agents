-- tests/db/core/test_fn_config_export.sql
-- core.fn_config_export: die eine Regel, welche Einstellung mit Sicherung und Umzug reist: managed_by='owner' und vom Standard
--   abweichend. Systemwerte und Instanz-Werte (managed_by 'system'/'instance', z. B. telegram.bot_username) reisen nie.
--   Muster: BEGIN…ROLLBACK, eigene Zeilen; RAISE EXCEPTION 'FAIL …' = Test rot.
BEGIN;

DO $$
DECLARE r jsonb;
BEGIN
  PERFORM core.fn_config_seed('{"category":"__tc","key":"same","value":"a","package":"__tpkg"}');
  PERFORM core.fn_config_seed('{"category":"__tc","key":"changed","value":"a","package":"__tpkg"}');
  PERFORM core.fn_config_seed('{"category":"__tc","key":"sys","value":"a","package":"__tpkg","managed_by":"system"}');
  PERFORM core.fn_config_seed('{"category":"__tc","key":"inst","value":"a","package":"__tpkg","managed_by":"instance"}');
  UPDATE core.config SET value = 'b' WHERE category = '__tc' AND key IN ('changed', 'inst');
  UPDATE core.config SET value = 'b' WHERE category = '__tc' AND key = 'sys';   -- Systemwert abweichend (ueberschreibt sonst der Seed)

  r := (SELECT jsonb_agg(e) FROM jsonb_array_elements(core.fn_config_export()) e WHERE e->>'category' = '__tc');
  IF jsonb_array_length(COALESCE(r, '[]')) <> 1 THEN RAISE EXCEPTION 'FAIL [1 genau eine Zeile] %', r; END IF;
  IF r->0 <> '{"package":"__tpkg","category":"__tc","key":"changed","value":"b"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [1 Form] %', r->0; END IF;
  RAISE NOTICE 'PASS [nur geaenderte Owner-Werte, ohne system/instance]';

  -- Instanz-Wert ueberlebt den Seed wie ein Owner-Wert (nie geaendert -> folgt dem Default, geaendert -> bleibt).
  PERFORM core.fn_config_seed('{"category":"__tc","key":"inst","value":"c","package":"__tpkg","managed_by":"instance"}');
  IF (SELECT value FROM core.config WHERE category = '__tc' AND key = 'inst') <> 'b' THEN
    RAISE EXCEPTION 'FAIL [2 instance-Wert vom Seed ueberschrieben]'; END IF;
  RAISE NOTICE 'PASS [instance-Wert bleibt beim Seed]';
END $$;

ROLLBACK;
