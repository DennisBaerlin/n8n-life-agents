-- tests/db/core/test_fn_config_import.sql
-- core.fn_config_import: Einstellungen aus Sicherung/Umzug einspielen. Gesetzt wird nur eine bekannte Owner-Zeile mit gueltigem
--   Wert; alles andere landet mit Grund in skipped[] (kein RAISE, nie der Wert). Owner-Zeilen, die das Bundle nicht nennt,
--   gehen auf ihren Standard zurueck (Restore = Stand der Sicherung, auch auf demselben Rechner).
--   Muster: BEGIN…ROLLBACK, eigene Zeilen; RAISE EXCEPTION 'FAIL …' = Test rot.
BEGIN;

DO $$
DECLARE r jsonb; s jsonb;
BEGIN
  PERFORM core.fn_config_seed('{"category":"__tc","key":"txt","value":"a","package":"__tpkg"}');
  PERFORM core.fn_config_seed('{"category":"__tc","key":"num","value":"5","package":"__tpkg","type":"integer","minimum":"1","maximum":"10"}');
  PERFORM core.fn_config_seed('{"category":"__tc","key":"later","value":"d","package":"__tpkg"}');
  PERFORM core.fn_config_seed('{"category":"__tc","key":"sys","value":"a","package":"__tpkg","managed_by":"system"}');
  PERFORM core.fn_config_seed('{"category":"__tc","key":"inst","value":"a","package":"__tpkg","managed_by":"instance"}');
  UPDATE core.config SET value = 'nach-der-sicherung' WHERE category = '__tc' AND key = 'later';
  UPDATE core.config SET value = 'eigener-bot' WHERE category = '__tc' AND key = 'inst';

  PERFORM core.fn_config_seed('{"category":"__tc","key":"fremd","value":"f","package":"__tfremd"}');
  UPDATE core.config SET value = 'eigener-wert' WHERE category = '__tc' AND key = 'fremd';
  r := core.fn_config_import(jsonb_build_object('packages', jsonb_build_array('__tpkg'), 'rows', jsonb_build_array(
         jsonb_build_object('key', 'ohne-kategorie', 'value', 'x'),
         jsonb_build_object('package', '__tpkg', 'category', '__tc', 'key', 'txt',  'value', 'b'),
         jsonb_build_object('package', '__tpkg', 'category', '__tc', 'key', 'num',  'value', '99'),
         jsonb_build_object('package', '__tpkg', 'category', '__tc', 'key', 'gone', 'value', 'x'),
         jsonb_build_object('package', '__tpkg', 'category', '__tc', 'key', 'sys',  'value', 'x'),
         jsonb_build_object('package', '__tpkg', 'category', '__tc', 'key', 'inst', 'value', 'alter-bot'))));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [0 ok] %', r; END IF;

  IF (SELECT value FROM core.config WHERE category = '__tc' AND key = 'txt') <> 'b' THEN RAISE EXCEPTION 'FAIL [1 txt nicht gesetzt]'; END IF;
  IF NOT r->'applied' @> '[{"category":"__tc","key":"txt","package":"__tpkg"}]' THEN RAISE EXCEPTION 'FAIL [1 applied] %', r->'applied'; END IF;
  RAISE NOTICE 'PASS [gueltiger Owner-Wert gesetzt]';

  IF (SELECT value FROM core.config WHERE category = '__tc' AND key = 'num') <> '5' THEN RAISE EXCEPTION 'FAIL [2 ungueltiger Wert uebernommen]'; END IF;
  s := r->'skipped';
  IF NOT s @> '[{"key":"num","reason":"invalid"}]' OR NOT s @> '[{"key":"gone","reason":"unknown"}]'
     OR NOT s @> '[{"key":"sys","reason":"system"}]' OR NOT s @> '[{"key":"inst","reason":"instance"}]' THEN
    RAISE EXCEPTION 'FAIL [2 skipped-Gruende] %', s; END IF;
  IF s::text LIKE '%99%' OR s::text LIKE '%alter-bot%' THEN RAISE EXCEPTION 'FAIL [2 Wert in skipped] %', s; END IF;
  IF (SELECT value FROM core.config WHERE category = '__tc' AND key = 'inst') <> 'eigener-bot' THEN RAISE EXCEPTION 'FAIL [2 instance ueberschrieben]'; END IF;
  RAISE NOTICE 'PASS [unbekannt/system/instance/ungueltig uebersprungen, ohne Wert]';

  IF (SELECT value FROM core.config WHERE category = '__tc' AND key = 'later') <> 'd' THEN RAISE EXCEPTION 'FAIL [3 spaetere Aenderung blieb]'; END IF;
  IF NOT r->'reset' @> '[{"category":"__tc","key":"later"}]' THEN RAISE EXCEPTION 'FAIL [3 reset] %', r->'reset'; END IF;
  RAISE NOTICE 'PASS [nicht genannte Owner-Zeile auf Standard, auch neben einer Zeile ohne category]';

  IF (SELECT value FROM core.config WHERE category = '__tc' AND key = 'fremd') <> 'eigener-wert' THEN
    RAISE EXCEPTION 'FAIL [3b Paket ausserhalb der Sicherung zurueckgesetzt]'; END IF;
  RAISE NOTICE 'PASS [Paket, das die Sicherung nicht kennt, behaelt seine Werte]';

  r := core.fn_config_import('{}'::jsonb);
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'rows_required' THEN RAISE EXCEPTION 'FAIL [4 ohne rows] %', r; END IF;
  RAISE NOTICE 'PASS [ohne rows -> ok:false]';
END $$;

ROLLBACK;
