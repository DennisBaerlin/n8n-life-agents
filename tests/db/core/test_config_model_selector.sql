-- test_config_model_selector.sql
-- Prueft: core.config (konfigurierte Modelle) x agent.ai_models (Registry) -- Integration ueber ALLE
-- model.*-Eintraege des geseedeten Bestands (keine hardcodierten Keys/Werte — welches Modell konfiguriert ist,
-- entscheidet der Betreiber):
--   (1) es gibt Modell-Eintraege, und jeder zeigt auf ein Modell mit befuellter n8n_model_id
--   (2) jeder Wert hat dieselbe Modell-Art (mode) wie sein Standard (core.fn_model_value_eligible) — bewusst
--       nicht "nur Chat", damit kuenftige Embedding-Eintraege moeglich bleiben
--   (3) die Chat-Modelle tragen lueckenlos selector_index 1..n (der Selector-Build verdrahtet Eingang
--       selector_index-1 bei numberInputs = n; eine Luecke ergaebe eine ungueltige Verbindung)
-- Existenz erzwingt der Fremdschluessel (core:V024); n8n-Selector-Aktivierung ist nur per LLM-Call pruefbar
-- -> implizit durch Tier-2 (n8n_test / orch_test).
BEGIN;
DO $$
DECLARE
    v_n    int;
    v_bad  text;
    v_chat int;
BEGIN
    SELECT count(*) INTO v_n FROM core.config WHERE category = 'model';
    IF v_n = 0 THEN RAISE EXCEPTION 'FAIL (1) keine model.*-Eintraege geseedet'; END IF;

    SELECT string_agg(c.key || '=' || c.value, ', ') INTO v_bad
      FROM core.config c LEFT JOIN agent.ai_models m ON m.model_key = c.value
     WHERE c.category = 'model' AND (m.model_key IS NULL OR COALESCE(m.n8n_model_id, '') = '');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FAIL (1) Modell fehlt/ohne n8n_model_id: %', v_bad; END IF;

    SELECT string_agg(key || '=' || value || ' (Standard ' || COALESCE(default_value, 'NULL') || ')', ', ') INTO v_bad
      FROM core.config
     WHERE category = 'model' AND NOT core.fn_model_value_eligible(value, default_value);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FAIL (2) Modell-Art passt nicht zum Standard: %', v_bad; END IF;

    SELECT count(*) INTO v_chat FROM agent.ai_models WHERE mode = 'chat';
    IF v_chat = 0
       OR (SELECT min(selector_index) FROM agent.ai_models WHERE mode = 'chat') <> 1
       OR (SELECT max(selector_index) FROM agent.ai_models WHERE mode = 'chat') <> v_chat THEN
        RAISE EXCEPTION 'FAIL (3) Chat-selector_index nicht lueckenlos 1..%: %', v_chat,
            (SELECT string_agg(model_key || '=' || selector_index, ', ' ORDER BY selector_index)
               FROM agent.ai_models WHERE mode = 'chat');
    END IF;

    RAISE NOTICE 'PASS config x ai_models: % Modell-Eintraege, % Chat-Modelle 1..%', v_n, v_chat, v_chat;
END $$;
ROLLBACK;
