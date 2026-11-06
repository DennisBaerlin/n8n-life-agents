-- tests/db/core/test_fn_config_seed.sql
-- Install-UX-Phase 4 (Schritt 1): core.fn_config_seed + core.fn_config_reset — dpkg-conffile-Semantik fuer
--   core.config. Der Seed (seed_data.sh::_seed_package_config) setzt default_value IMMER auf den Manifest-Wert,
--   ueberschreibt value aber NUR, wenn der Owner ihn nie geaendert hat (value IS NOT DISTINCT FROM altem
--   default_value). Bestandszeilen (default_value NULL) gelten als vom Owner gesetzt. Ausnahmen: cron_enable
--   (Laufzeit-Schalter, nie ueberschreiben), managed_by='system' (System-Werte, immer ueberschreiben), model mit einem nicht
--   (mehr) bekannten model_key (zurueck auf den Default, sonst blockiert der Modell-Trigger den Seed).
--   Muster: BEGIN…ROLLBACK, eigene Zeilen; RAISE EXCEPTION 'FAIL …' = Test rot.
BEGIN;

DO $$
DECLARE r jsonb; v text; d text;
BEGIN
  -- (1) Erst-Seed: Zeile entsteht mit value = default_value = Manifest-Wert.
  r := core.fn_config_seed('{"category":"general","key":"__t_url","value":"","description":"d1","package":"__tpkg"}');
  SELECT value, default_value INTO v, d FROM core.config WHERE category='general' AND key='__t_url';
  IF v IS DISTINCT FROM '' OR d IS DISTINCT FROM '' THEN RAISE EXCEPTION 'FAIL [1 erst-seed] value=% default=%', v, d; END IF;
  IF r->>'action' <> 'inserted' THEN RAISE EXCEPTION 'FAIL [1 action] %', r; END IF;

  -- (2) Neuer Manifest-Default, Owner hat nie geaendert -> value folgt dem Default.
  r := core.fn_config_seed('{"category":"general","key":"__t_url","value":"http://default","description":"d2","package":"__tpkg"}');
  SELECT value, default_value INTO v, d FROM core.config WHERE category='general' AND key='__t_url';
  IF v <> 'http://default' OR d <> 'http://default' THEN RAISE EXCEPTION 'FAIL [2 default folgt] value=% default=%', v, d; END IF;
  IF (SELECT description FROM core.config WHERE category='general' AND key='__t_url') <> 'd2' THEN RAISE EXCEPTION 'FAIL [2 description]'; END IF;

  -- (3) Owner setzt einen eigenen Wert (beliebiger Schreibweg = plain UPDATE) -> naechster Seed behaelt ihn.
  UPDATE core.config SET value='http://paperless.lan:8000' WHERE category='general' AND key='__t_url';
  r := core.fn_config_seed('{"category":"general","key":"__t_url","value":"http://newdefault","description":"d3","package":"__tpkg"}');
  SELECT value, default_value INTO v, d FROM core.config WHERE category='general' AND key='__t_url';
  IF v <> 'http://paperless.lan:8000' THEN RAISE EXCEPTION 'FAIL [3 owner-wert ueberschrieben] value=%', v; END IF;
  IF d <> 'http://newdefault' THEN RAISE EXCEPTION 'FAIL [3 default nicht nachgezogen] default=%', d; END IF;
  IF r->>'action' <> 'kept' THEN RAISE EXCEPTION 'FAIL [3 action] %', r; END IF;

  -- (4) Reset: value := default_value.
  r := core.fn_config_reset('{"category":"general","key":"__t_url"}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4 reset ok] %', r; END IF;
  SELECT value INTO v FROM core.config WHERE category='general' AND key='__t_url';
  IF v <> 'http://newdefault' THEN RAISE EXCEPTION 'FAIL [4 reset value] %', v; END IF;
  -- nach dem Reset folgt der Wert wieder dem Default
  PERFORM core.fn_config_seed('{"category":"general","key":"__t_url","value":"http://d4","description":"","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE category='general' AND key='__t_url') <> 'http://d4' THEN RAISE EXCEPTION 'FAIL [4 nach reset folgt]'; END IF;
  -- Reset eines unbekannten Keys -> {ok:false}
  r := core.fn_config_reset('{"category":"general","key":"__does_not_exist"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4 reset unbekannt] %', r; END IF;

  -- (5) Bestandszeile aus der Zeit vor default_value (NULL) mit Owner-Wert -> bleibt.
  INSERT INTO core.config (category, key, value, description, package, default_value)
  VALUES ('general', '__t_legacy', 'owner-value', '', '__tpkg', NULL);
  PERFORM core.fn_config_seed('{"category":"general","key":"__t_legacy","value":"manifest","description":"","package":"__tpkg"}');
  SELECT value, default_value INTO v, d FROM core.config WHERE category='general' AND key='__t_legacy';
  IF v <> 'owner-value' OR d <> 'manifest' THEN RAISE EXCEPTION 'FAIL [5 bestand] value=% default=%', v, d; END IF;
  -- Bestandszeile mit value = aktueller Default -> danach folgt sie kuenftigen Defaults
  INSERT INTO core.config (category, key, value, description, package, default_value)
  VALUES ('general', '__t_legacy2', 'same', '', '__tpkg', NULL);
  PERFORM core.fn_config_seed('{"category":"general","key":"__t_legacy2","value":"same","description":"","package":"__tpkg"}');
  PERFORM core.fn_config_seed('{"category":"general","key":"__t_legacy2","value":"next","description":"","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE category='general' AND key='__t_legacy2') <> 'next' THEN RAISE EXCEPTION 'FAIL [5 bestand gleich default]'; END IF;

  -- (6) cron_enable: Laufzeit-Schalter, NIE ueberschreiben (auch wenn nie geaendert).
  PERFORM core.fn_config_seed('{"category":"cron_enable","key":"__t_cron","value":"true","description":"","package":"__tpkg"}');
  UPDATE core.config SET value='false' WHERE category='cron_enable' AND key='__t_cron';
  PERFORM core.fn_config_seed('{"category":"cron_enable","key":"__t_cron","value":"true","description":"","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE category='cron_enable' AND key='__t_cron') <> 'false' THEN RAISE EXCEPTION 'FAIL [6 cron_enable ueberschrieben]'; END IF;

  -- (7) managed_by='system' (z. B. api.core_version): System-Wert, IMMER ueberschreiben. Die Kategorie allein
  --     entscheidet das nicht mehr (ohne managed_by gilt auch api.* als Owner-Wert).
  PERFORM core.fn_config_seed('{"category":"api","key":"__t_ver","value":"1","description":"","managed_by":"system","package":"__tpkg"}');
  UPDATE core.config SET value='hand' WHERE category='api' AND key='__t_ver';
  PERFORM core.fn_config_seed('{"category":"api","key":"__t_ver","value":"2","description":"","managed_by":"system","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE category='api' AND key='__t_ver') <> '2' THEN RAISE EXCEPTION 'FAIL [7 system-wert nicht ueberschrieben]'; END IF;

  -- (8) model: Owner-Wert bleibt, solange er zur Modell-Art (agent.ai_models.mode) des Standards passt
  --     (core.fn_model_value_eligible). Wechselt der Standard die Art (chat -> embedding), setzt der Seed den
  --     Owner-Wert auf den neuen Standard zurueck (sonst blockierte der Modell-Trigger den ganzen Seed). Ein
  --     verwaister Wert ist seit core:V024 unmoeglich (Fremdschluessel) -> kein eigener Fall mehr.
  INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode)
  VALUES ('__t_m1', 'x', 'm1', 901, 'chat'), ('__t_m2', 'x', 'm2', 902, 'chat'), ('__t_e1', 'x', 'e1', NULL, 'embedding')
  ON CONFLICT (model_key) DO NOTHING;
  PERFORM core.fn_config_seed('{"category":"model","key":"__t_agent","value":"__t_m1","description":"","package":"__tpkg"}');
  UPDATE core.config SET value='__t_m2' WHERE category='model' AND key='__t_agent';
  PERFORM core.fn_config_seed('{"category":"model","key":"__t_agent","value":"__t_m1","description":"","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE category='model' AND key='__t_agent') <> '__t_m2' THEN RAISE EXCEPTION 'FAIL [8 gueltiger owner-modellwert nicht behalten]'; END IF;
  PERFORM core.fn_config_seed('{"category":"model","key":"__t_agent","value":"__t_e1","description":"","package":"__tpkg"}');
  IF (SELECT value FROM core.config WHERE category='model' AND key='__t_agent') <> '__t_e1' THEN RAISE EXCEPTION 'FAIL [8 owner-wert falscher modell-art nicht zurueckgesetzt]'; END IF;

  -- (9) Besitzer-Wechsel (Phase C: feature.onboarding_gate zog core -> finance): deklariert ein anderes Paket den
  --     Key, stempelt der naechste Seed `package` neu; ein Owner-Wert bleibt (conffile-Regel unabhaengig vom Besitzer).
  PERFORM core.fn_config_seed('{"category":"feature","key":"__t_move","value":"true","description":"","package":"__tcore"}');
  UPDATE core.config SET value='false' WHERE category='feature' AND key='__t_move';
  r := core.fn_config_seed('{"category":"feature","key":"__t_move","value":"true","description":"","package":"__tpkg"}');
  SELECT value, package INTO v, d FROM core.config WHERE category='feature' AND key='__t_move';
  IF d <> '__tpkg' THEN RAISE EXCEPTION 'FAIL [9 package nicht neu gestempelt] package=%', d; END IF;
  IF v <> 'false' THEN RAISE EXCEPTION 'FAIL [9 owner-wert beim besitzer-wechsel verloren] value=%', v; END IF;

  -- (10) Pflichtfelder: fehlende category/key -> {ok:false} statt Exception.
  r := core.fn_config_seed('{"key":"x","value":"y"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [10 pflichtfeld] %', r; END IF;

  -- (11) summary (deutscher Owner-Einzeiler fuer `lifeagents config list`): wie description IMMER aus dem
  --      Manifest — gesetzt beim Erst-Seed, ueberschrieben beim Re-Seed, fehlender Key -> ''.
  PERFORM core.fn_config_seed('{"category":"general","key":"__t_sum","value":"1","description":"","summary":"Satz eins","package":"__tpkg"}');
  IF (SELECT summary FROM core.config WHERE category='general' AND key='__t_sum') IS DISTINCT FROM 'Satz eins' THEN RAISE EXCEPTION 'FAIL [11 summary insert]'; END IF;
  UPDATE core.config SET value='2' WHERE category='general' AND key='__t_sum';   -- Owner-Wert: summary folgt trotzdem
  PERFORM core.fn_config_seed('{"category":"general","key":"__t_sum","value":"1","description":"","summary":"Satz zwei","package":"__tpkg"}');
  IF (SELECT summary FROM core.config WHERE category='general' AND key='__t_sum') IS DISTINCT FROM 'Satz zwei' THEN RAISE EXCEPTION 'FAIL [11 summary re-seed]'; END IF;
  PERFORM core.fn_config_seed('{"category":"general","key":"__t_sum","value":"1","description":"","package":"__tpkg"}');
  IF (SELECT summary FROM core.config WHERE category='general' AND key='__t_sum') IS DISTINCT FROM '' THEN RAISE EXCEPTION 'FAIL [11 summary fehlt -> leer]'; END IF;

  RAISE NOTICE 'PASS core.fn_config_seed/fn_config_reset [conffile-Matrix]';
END $$;

-- (12) DB-Gesetz config_summary_single_line: summary ohne Steuerzeichen (die CLI liest Zeilen mit \x1f-Trenner
--      zeilenweise — ein Zeilenumbruch oder \x1f im Satz verschoebe die Spalten).
DO $$
DECLARE v_bad text;
BEGIN
  FOREACH v_bad IN ARRAY ARRAY[E'a\nb', E'a\x1fb', E'a\tb'] LOOP
    BEGIN
      INSERT INTO core.config (category, key, value, summary, package) VALUES ('general', '__t_ctl', 'x', v_bad, '__tpkg');
      RAISE EXCEPTION 'FAIL [12 steuerzeichen akzeptiert] %', quote_literal(v_bad);
    EXCEPTION WHEN check_violation THEN
      NULL;   -- erwartet
    END;
  END LOOP;
  RAISE NOTICE 'PASS core.config.summary [config_summary_single_line]';
END $$;

ROLLBACK;
