-- tests/db/core/test_core_config_package.sql
-- WS4a: core.config bekommt eine `package`-Spalte (Ownership/Uninstall-Scope; Info, NICHT Teil der Uniqueness).
--   Prueft: Default 'core', explizites Paket bleibt, UNIQUE(category,key) bleibt global (paket-uebergreifend),
--   und der bestehende category='model'->agent.ai_models-Validierungstrigger greift weiter (Spalte bricht ihn nicht).
--   Muster: BEGIN…ROLLBACK. db_test hat kein seed_data -> ai_models/config sind leer, wir seeden selbst.
BEGIN;

-- ---------- package-Spalte: Default + explizit ----------
DO $$
DECLARE v_pkg text;
BEGIN
  INSERT INTO core.config (category, key, value) VALUES ('__t_cat__', 'no_pkg', 'v');
  SELECT package INTO v_pkg FROM core.config WHERE category='__t_cat__' AND key='no_pkg';
  IF v_pkg IS DISTINCT FROM 'core' THEN RAISE EXCEPTION 'FAIL [package default <> core]: %', v_pkg; END IF;

  INSERT INTO core.config (category, key, value, package) VALUES ('__t_cat__', 'fin', 'v', 'finance');
  SELECT package INTO v_pkg FROM core.config WHERE category='__t_cat__' AND key='fin';
  IF v_pkg IS DISTINCT FROM 'finance' THEN RAISE EXCEPTION 'FAIL [explicit package not stored]: %', v_pkg; END IF;

  RAISE NOTICE 'PASS core.config.package [Default core + explizit]';
END $$;

-- ---------- UNIQUE(category,key) bleibt GLOBAL (package ist nicht Teil der Uniqueness) ----------
DO $$
DECLARE v_conflict boolean := false;
BEGIN
  INSERT INTO core.config (category, key, value, package) VALUES ('__t_uniq__', 'k', 'a', 'core');
  BEGIN
    -- gleiche (category,key), anderes Paket -> MUSS am UNIQUE scheitern (Schluessel global eindeutig,
    -- damit die CLI eine Zeile ohne Paket-Wissen adressiert).
    INSERT INTO core.config (category, key, value, package) VALUES ('__t_uniq__', 'k', 'b', 'finance');
  EXCEPTION WHEN unique_violation THEN v_conflict := true;
  END;
  IF NOT v_conflict THEN RAISE EXCEPTION 'FAIL [UNIQUE(category,key) nicht global -> dieselbe (cat,key) in 2 Paketen]'; END IF;

  RAISE NOTICE 'PASS core.config UNIQUE(category,key) global';
END $$;

-- ---------- Model-Enum-Trigger greift weiter (Spalte hat ihn nicht gebrochen) ----------
DO $$
DECLARE v_raised boolean := false;
BEGIN
  INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode)
  VALUES ('__t_modelkey__', 'Anthropic', 'x', 991, 'chat');

  -- gueltiger Modell-Wert (existiert in ai_models) -> ok, mit Paket-Tag
  INSERT INTO core.config (category, key, value, package) VALUES ('model', '__t_mkey__', '__t_modelkey__', 'finance');

  -- ungueltiger Modell-Wert -> Trigger RAISE
  BEGIN
    INSERT INTO core.config (category, key, value, package) VALUES ('model', '__t_bad__', '__does_not_exist__', 'finance');
  EXCEPTION WHEN others THEN v_raised := true;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [model-trigger liess unbekannten model_key durch]'; END IF;

  RAISE NOTICE 'PASS core.config model-trigger [greift mit package-Spalte unveraendert]';
END $$;

ROLLBACK;
