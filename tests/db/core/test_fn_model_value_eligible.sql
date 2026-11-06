-- tests/db/core/test_fn_model_value_eligible.sql
-- Modell-Phase 2: core.fn_model_value_eligible(value, default) = die EINE Regel "welches Modell passt in einen
-- Modell-Eintrag" (Trigger trg_config_check_model_value, Seed-Guard fn_config_seed, CLI-Auswahl):
--   (1) Wert existiert + gleiche Modell-Art (mode) wie der Standard -> true
--   (2) Wert unbekannt -> false
--   (3) chat <-> embedding -> false (beide Richtungen)
--   (4) Standard NULL (Bestandszeile ohne default_value) -> nur "existiert"
--   (5) Standard unbekannt -> false
--   (6) Trigger: falsche Art wird mit check_violation abgelehnt, richtige Art angenommen
--   (7) Trigger feuert nur bei Aenderung von value/default_value (anderes UPDATE bricht nie ab)
-- plus die Register-CHECKs: mode-Enum + Paarung mode/selector_index.
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  v_blocked boolean;
  v_state   text;
BEGIN
  INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode) VALUES
    ('__t_chat_a', 'Anthropic', 'a', 991, 'chat'),
    ('__t_chat_b', 'Anthropic', 'b', 992, 'chat'),
    ('__t_emb',    'Google',    'e', NULL, 'embedding');

  -- (1)-(5) die Funktion selbst
  IF NOT core.fn_model_value_eligible('__t_chat_a', '__t_chat_b') THEN RAISE EXCEPTION 'FAIL (1) chat/chat abgelehnt'; END IF;
  IF NOT core.fn_model_value_eligible('__t_emb', '__t_emb') THEN RAISE EXCEPTION 'FAIL (1) emb/emb abgelehnt'; END IF;
  IF core.fn_model_value_eligible('__t_nope', '__t_chat_a') THEN RAISE EXCEPTION 'FAIL (2) unbekannter Wert angenommen'; END IF;
  IF core.fn_model_value_eligible('__t_emb', '__t_chat_a') THEN RAISE EXCEPTION 'FAIL (3) emb in chat-Eintrag angenommen'; END IF;
  IF core.fn_model_value_eligible('__t_chat_a', '__t_emb') THEN RAISE EXCEPTION 'FAIL (3) chat in emb-Eintrag angenommen'; END IF;
  IF NOT core.fn_model_value_eligible('__t_emb', NULL) THEN RAISE EXCEPTION 'FAIL (4) NULL-Standard abgelehnt'; END IF;
  IF core.fn_model_value_eligible('__t_nope', NULL) THEN RAISE EXCEPTION 'FAIL (4) unbekannt bei NULL-Standard angenommen'; END IF;
  IF core.fn_model_value_eligible('__t_chat_a', '__t_nope') THEN RAISE EXCEPTION 'FAIL (5) unbekannter Standard angenommen'; END IF;

  -- (6) Trigger
  INSERT INTO core.config (category, key, value, default_value, package)
  VALUES ('model', '__t_slot', '__t_chat_a', '__t_chat_a', '__tpkg');
  UPDATE core.config SET value = '__t_chat_b' WHERE category = 'model' AND key = '__t_slot';   -- gleiche Art -> ok
  v_state := NULL;
  BEGIN
    UPDATE core.config SET value = '__t_emb' WHERE category = 'model' AND key = '__t_slot';
  EXCEPTION WHEN check_violation THEN v_state := 'check_violation';
  END;
  IF v_state IS DISTINCT FROM 'check_violation' THEN RAISE EXCEPTION 'FAIL (6) falsche Art nicht mit check_violation abgelehnt'; END IF;

  -- (7) ein UPDATE, das value/default_value nicht aendert, prueft nicht (Bestandswert bricht kein Update ab)
  ALTER TABLE core.config DISABLE TRIGGER trg_config_check_model_value;
  UPDATE core.config SET value = '__t_emb' WHERE category = 'model' AND key = '__t_slot';     -- Altlast simulieren
  ALTER TABLE core.config ENABLE TRIGGER trg_config_check_model_value;
  UPDATE core.config SET summary = 'neu' WHERE category = 'model' AND key = '__t_slot';       -- darf nicht abbrechen

  -- Register-CHECKs
  v_blocked := false;
  BEGIN
    INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode) VALUES ('__t_bad1', 'x', 'x', NULL, 'chat');
  EXCEPTION WHEN check_violation THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL CHECK chat ohne selector_index angenommen'; END IF;
  v_blocked := false;
  BEGIN
    INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode) VALUES ('__t_bad2', 'x', 'x', 993, 'embedding');
  EXCEPTION WHEN check_violation THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL CHECK embedding mit selector_index angenommen'; END IF;
  v_blocked := false;
  BEGIN
    INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode) VALUES ('__t_bad3', 'x', 'x', 994, 'vision');
  EXCEPTION WHEN check_violation THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL CHECK unbekannte Modell-Art angenommen'; END IF;
  v_blocked := false;
  BEGIN
    INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index) VALUES ('__t_bad4', 'x', 'x', 995);
  EXCEPTION WHEN not_null_violation THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL NOT NULL mode fehlt'; END IF;

  RAISE NOTICE 'PASS core.fn_model_value_eligible (Regel + Trigger + Register-CHECKs)';
END $$;

ROLLBACK;
