-- tests/db/core/test_config_value_checks.sql
-- core.config: typisierte Werte (value_type/minimum/maximum, Muster pg_settings.vartype/min_val/max_val) +
--   managed_by (owner|system). Geprueft:
--   (1) core.fn_config_cron_valid gegen die gemeinsame Fallliste tests/util/util_cron_cases.sql (dieselbe, die
--       scripts/config_test.ps1 fuer die Manifest-Defaults nutzt).
--   (2) Trigger trg_config_check_value_type: falscher Wert je Typ -> check_violation; gueltiger -> akzeptiert.
--   (3) Pruefung NUR bei Wertaenderung: ein vorhandener ungueltiger Bestandswert bricht ein UPDATE anderer
--       Spalten nicht ab (ein Update darf nie an einem alten Owner-Wert scheitern).
--   (4) Seed setzt einen ungueltigen Bestandswert auf den Standard zurueck (NOTICE) + uebernimmt Typ/Grenzen.
--   (5) Spalten-CHECKs: unbekannter Typ, Grenze an einem Nicht-Zahl-Typ, minimum > maximum, managed_by-Enum.
--   (6) Geseedeter Stand: jede schedule-Zeile ist value_type='cron', jede cron_enable-Zeile 'boolean',
--       api.core_version ist managed_by='system', die Abgleich-Schwelle ist integer >= 1, feature.prompt_caching ist weg.
BEGIN;

\ir ../../util/util_cron_cases.sql

DO $$
DECLARE c jsonb; n int := 0;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(current_setting('lifeagents.cron_cases')::jsonb) LOOP
    IF core.fn_config_cron_valid(c->>'cron') IS DISTINCT FROM (c->>'valid')::boolean THEN
      RAISE EXCEPTION 'FAIL [1 cron] "%" erwartet valid=%, bekam %', c->>'cron', c->>'valid', core.fn_config_cron_valid(c->>'cron');
    END IF;
    n := n + 1;
  END LOOP;
  IF n < 10 THEN RAISE EXCEPTION 'FAIL [1 cron] Fallliste nicht geladen (% Fälle)', n; END IF;
  IF core.fn_config_cron_valid(NULL) IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 cron] NULL muss ungültig sein'; END IF;
  RAISE NOTICE 'PASS core.fn_config_cron_valid [% Fälle aus util_cron_cases]', n;
END $$;

DO $$
DECLARE v_bad text; v_case record;
BEGIN
  INSERT INTO core.config (category, key, value, package, value_type)               VALUES ('schedule', '__t_cron', '0 7 * * 1-5', '__tpkg', 'cron');
  INSERT INTO core.config (category, key, value, package, value_type, minimum)      VALUES ('__tcat', '__t_int', '30', '__tpkg', 'integer', 1);
  INSERT INTO core.config (category, key, value, package, value_type, minimum, maximum) VALUES ('__tcat', '__t_num', '0.10', '__tpkg', 'number', 0, 1);
  INSERT INTO core.config (category, key, value, package, value_type)               VALUES ('__tcat', '__t_bool', 'true', '__tpkg', 'boolean');
  INSERT INTO core.config (category, key, value, package)                           VALUES ('__tcat', '__t_str', 'irgendwas', '__tpkg');

  -- (2) je Typ ungueltige Werte -> check_violation
  FOR v_case IN SELECT * FROM (VALUES
      ('__t_cron', '* * * * * *'), ('__t_cron', 'jeden Tag'),
      ('__t_int', 'abc'), ('__t_int', '0'), ('__t_int', '1.5'), ('__t_int', ''),
      ('__t_int', '2147483648'), ('__t_int', '99999999999'),   -- jenseits int4: Verbraucher casten ::int
      ('__t_num', '1.5'), ('__t_num', '-0.1'), ('__t_num', '10%'),
      ('__t_bool', 'yes'), ('__t_bool', 'TRUE'), ('__t_bool', '')
    ) AS t(k, v) LOOP
    BEGIN
      UPDATE core.config SET value = v_case.v WHERE key = v_case.k;
      RAISE EXCEPTION 'FAIL [2 typ] % = "%" wurde akzeptiert', v_case.k, v_case.v;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
  END LOOP;

  -- gueltige Werte -> akzeptiert (string ist frei)
  UPDATE core.config SET value = '30 6 * * *' WHERE key = '__t_cron';
  UPDATE core.config SET value = '2147483647' WHERE key = '__t_int';   -- int4-Obergrenze noch gueltig
  UPDATE core.config SET value = '1'          WHERE key = '__t_int';
  UPDATE core.config SET value = '1'          WHERE key = '__t_num';
  UPDATE core.config SET value = 'false'      WHERE key = '__t_bool';
  UPDATE core.config SET value = ''           WHERE key = '__t_str';

  -- auch der INSERT wird geprueft
  BEGIN
    INSERT INTO core.config (category, key, value, package, value_type) VALUES ('schedule', '__t_cron2', '61 * * * *', '__tpkg', 'cron');
    RAISE EXCEPTION 'FAIL [2 insert] ungültiger Cron beim INSERT akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS trg_config_check_value_type [cron/integer/number/boolean, INSERT+UPDATE]';
END $$;

-- (3) + (4): Bestandswert, der zum (neuen) Typ nicht passt. Pflanzen mit abgeschaltetem Pruef-Trigger (Superuser,
--     nur in dieser Test-Transaktion) = der Zustand einer Instanz von vor der Typisierung.
ALTER TABLE core.config DISABLE TRIGGER trg_config_check_value_type;
INSERT INTO core.config (category, key, value, package, value_type, minimum, default_value)
VALUES ('__tcat', '__t_legacy_int', 'abc', '__tpkg', 'integer', 1, '30');
ALTER TABLE core.config ENABLE TRIGGER trg_config_check_value_type;

DO $$
DECLARE r jsonb; v text;
BEGIN
  -- (3) UPDATE ohne Wertaenderung -> keine Pruefung, kein Abbruch
  UPDATE core.config SET description = 'neu' WHERE key = '__t_legacy_int';
  IF (SELECT description FROM core.config WHERE key = '__t_legacy_int') <> 'neu' THEN RAISE EXCEPTION 'FAIL [3 update]'; END IF;

  -- (4) Re-Seed: der ungueltige Owner-Wert faellt auf den Standard zurueck
  r := core.fn_config_seed('{"category":"__tcat","key":"__t_legacy_int","value":"30","type":"integer","minimum":"1","package":"__tpkg"}');
  SELECT value INTO v FROM core.config WHERE key = '__t_legacy_int';
  IF v <> '30' THEN RAISE EXCEPTION 'FAIL [4 seed-reset] value=% (r=%)', v, r; END IF;
  IF r->>'action' <> 'updated' THEN RAISE EXCEPTION 'FAIL [4 action] %', r; END IF;

  -- Seed uebernimmt Typ + Grenzen aus dem Manifest; ein GUELTIGER Owner-Wert bleibt
  PERFORM core.fn_config_seed('{"category":"__tcat","key":"__t_seeded","value":"5","type":"integer","minimum":"1","maximum":"9","package":"__tpkg"}');
  IF (SELECT (value_type, minimum, maximum) FROM core.config WHERE key = '__t_seeded') IS DISTINCT FROM ('integer'::text, 1::numeric, 9::numeric) THEN
    RAISE EXCEPTION 'FAIL [4 seed typ] %', (SELECT row(value_type, minimum, maximum) FROM core.config WHERE key = '__t_seeded');
  END IF;
  UPDATE core.config SET value = '7' WHERE key = '__t_seeded';
  PERFORM core.fn_config_seed('{"category":"__tcat","key":"__t_seeded","value":"5","type":"integer","minimum":"1","maximum":"9","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE key = '__t_seeded') <> '7' THEN RAISE EXCEPTION 'FAIL [4 gültiger owner-wert verloren]'; END IF;
  -- ... faellt aber zurueck, wenn eine neue Obergrenze ihn ausschliesst
  PERFORM core.fn_config_seed('{"category":"__tcat","key":"__t_seeded","value":"5","type":"integer","minimum":"1","maximum":"6","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE key = '__t_seeded') <> '5' THEN RAISE EXCEPTION 'FAIL [4 neue grenze]'; END IF;
  -- Typ entfaellt im Manifest -> zurueck auf string, Grenzen weg
  PERFORM core.fn_config_seed('{"category":"__tcat","key":"__t_seeded","value":"5","package":"__tpkg"}');
  IF (SELECT (value_type, minimum, maximum) FROM core.config WHERE key = '__t_seeded') IS DISTINCT FROM ('string'::text, NULL::numeric, NULL::numeric) THEN
    RAISE EXCEPTION 'FAIL [4 typ entfällt]';
  END IF;

  -- managed_by='system': jeder Seed setzt den ausgelieferten Wert, auch wenn er geaendert wurde
  PERFORM core.fn_config_seed('{"category":"__tcat","key":"__t_sys","value":"1","managed_by":"system","package":"__tpkg"}');
  UPDATE core.config SET value = 'hand' WHERE key = '__t_sys';
  PERFORM core.fn_config_seed('{"category":"__tcat","key":"__t_sys","value":"2","managed_by":"system","package":"__tpkg"}');
  IF (SELECT (value, managed_by) FROM core.config WHERE key = '__t_sys') IS DISTINCT FROM ('2'::text, 'system'::text) THEN
    RAISE EXCEPTION 'FAIL [4 system-wert] %', (SELECT row(value, managed_by) FROM core.config WHERE key = '__t_sys');
  END IF;
  RAISE NOTICE 'PASS Prüfung nur bei Wertänderung + Seed-Rücksetzen + managed_by';
END $$;

DO $$
DECLARE v_sql text;
BEGIN
  -- (5) Spalten-CHECKs
  FOREACH v_sql IN ARRAY ARRAY[
    $q$INSERT INTO core.config (category, key, value, package, value_type) VALUES ('__tcat','__t_c1','x','__tpkg','enum')$q$,
    $q$INSERT INTO core.config (category, key, value, package, value_type, minimum) VALUES ('__tcat','__t_c2','x','__tpkg','string',1)$q$,
    $q$INSERT INTO core.config (category, key, value, package, value_type, minimum, maximum) VALUES ('__tcat','__t_c3','5','__tpkg','integer',9,1)$q$,
    $q$INSERT INTO core.config (category, key, value, package, managed_by) VALUES ('__tcat','__t_c4','x','__tpkg','agent')$q$
  ] LOOP
    BEGIN
      EXECUTE v_sql;
      RAISE EXCEPTION 'FAIL [5 check] akzeptiert: %', v_sql;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
  END LOOP;
  RAISE NOTICE 'PASS core.config Spalten-CHECKs [value_type/Grenzen/managed_by]';
END $$;

DO $$
BEGIN
  -- (6) geseedeter Stand (bootstrap_test_db seedet die Manifeste ueber core.fn_config_seed)
  IF EXISTS (SELECT 1 FROM core.config WHERE category = 'schedule' AND value_type <> 'cron' AND key NOT LIKE '\_\_t%') THEN
    RAISE EXCEPTION 'FAIL [6] schedule-Zeile ohne value_type=cron: %',
      (SELECT string_agg(key, ', ') FROM core.config WHERE category = 'schedule' AND value_type <> 'cron');
  END IF;
  IF EXISTS (SELECT 1 FROM core.config WHERE category = 'cron_enable' AND value_type <> 'boolean') THEN
    RAISE EXCEPTION 'FAIL [6] cron_enable-Zeile ohne value_type=boolean';
  END IF;
  IF (SELECT managed_by FROM core.config WHERE category = 'api' AND key = 'core_version') IS DISTINCT FROM 'system' THEN
    RAISE EXCEPTION 'FAIL [6] api.core_version nicht managed_by=system';
  END IF;
  IF (SELECT (value_type, minimum) FROM core.config WHERE category = 'finance' AND key = 'coverage_buffer_eur')
     IS DISTINCT FROM ('number'::text, 0::numeric) THEN
    RAISE EXCEPTION 'FAIL [6] finance.coverage_buffer_eur nicht number >= 0';
  END IF;
  IF EXISTS (SELECT 1 FROM core.config WHERE category = 'feature' AND key = 'prompt_caching') THEN
    RAISE EXCEPTION 'FAIL [6] feature.prompt_caching existiert noch';
  END IF;
  -- jede geseedete Zeile ist unter ihrem eigenen Typ gueltig (Manifest-Defaults + Seed-Ruecksetzen)
  IF EXISTS (SELECT 1 FROM core.config WHERE NOT core.fn_config_value_valid(value_type, value, minimum, maximum)) THEN
    RAISE EXCEPTION 'FAIL [6] ungültige geseedete Zeile: %',
      (SELECT string_agg(category || '/' || key || '=' || value, ', ') FROM core.config
        WHERE NOT core.fn_config_value_valid(value_type, value, minimum, maximum));
  END IF;
  RAISE NOTICE 'PASS geseedeter Stand [schedule=cron, cron_enable=boolean, api=system, Schwelle integer>=1, prompt_caching weg]';
END $$;

ROLLBACK;
