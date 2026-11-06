-- ============================================================
-- V024 (core) — Modell-Phase 2: Gemini als Sprachmodell entfernen + Modell-Register als DB-Gesetz
--
--   Owner-Regel (2026-10-19): was gemini-2.5-flash war, wird claude-haiku-latest; jedes andere Gemini-Chat-Modell
--   wird claude-sonnet-latest. Google bleibt nur fuer Embeddings (mode='embedding', unbenutzt) und die
--   Sprach-Transkription (kein Register-Eintrag, fest im Tool).
--
--   Reihenfolge (jede Stufe macht die naechste moeglich):
--     1. agent.ai_models.mode nachfuellen (aus selector_index) + NOT NULL — Spalte/CHECKs legt der Init an.
--     2. Altlasten vor dem FK: ein Modell-default_value auf kein Modell -> NULL (gilt dann als Owner-Wert, der
--        naechste Seed setzt ihn neu); ein Modell-value auf kein Modell oder der falschen Art -> sein (gueltiger)
--        Standard, sonst claude-sonnet-latest. Beides in EINEM UPDATE, damit der Modell-Trigger nur fertige Zeilen sieht.
--     3. value UND default_value jeder Modell-Zeile nach der Owner-Regel umschreiben — auch Zeilen nicht
--        installierter Pakete (sonst blockierte der FK das Loeschen in Stufe 4).
--     4. Die Gemini-Chat-Zeilen loeschen.
--     5. Fremdschluessel model_ref/model_default_ref -> agent.ai_models(model_key) ON DELETE RESTRICT (die
--        generierten Spalten legt core.config_init.sql an). Bewusst hier statt im Init: die Inits bleiben
--        reihenfolge-tolerant (packages/CLAUDE.md *Apply-Eigenheit*).
--   Umnummerieren der Chat-Modelle (2/4/6 -> 1/2/3) macht der Seed danach aus ai_models.json: je Modell eine
--   Anweisung in JSON-Reihenfolge, kollisionsfrei, sobald die Gemini-Zeilen weg sind. Bis dahin haben die Nummern
--   keine Laufzeitwirkung (der Umschalter vergleicht model_key).
--
--   Frische DB: Tabellen leer -> Stufen 1-4 No-op, Stufe 5 legt die FKs an. Wiederholbar (der Migrationstest
--   faehrt die Datei zweimal): jede Stufe ist idempotent, die FKs sind geguardet.
--   Kein BEGIN/COMMIT (der Treiber wrapt). squawk: SET NOT NULL -> globale Ausnahme adding-not-nullable-field
--   (config/.squawk.toml, winzige Tabelle).
-- APPLY-ORDER: Inits -> V (hier) -> R -> Seed.
-- ============================================================

-- 1. Modell-Art nachfuellen
UPDATE agent.ai_models
   SET mode = CASE WHEN selector_index IS NULL THEN 'embedding' ELSE 'chat' END
 WHERE mode IS NULL;
ALTER TABLE agent.ai_models ALTER COLUMN mode SET NOT NULL;

-- 2. Altlasten vor dem FK bereinigen: jede Modell-Zeile, die die Regel core.fn_model_value_eligible (bekanntes
--    Modell derselben Art wie der Standard) verletzt — verwaister Wert, verwaister Standard oder ein Wert der falschen
--    Art (z. B. ein Embedding-Modell, das die alte CLI-Auswahl zuliess). Sonst braeche der Modell-Trigger beim
--    Umschreiben in Stufe 3 die ganze Migration ab.
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT c.key, c.value, c.default_value FROM core.config c
         WHERE c.category = 'model' AND NOT core.fn_model_value_eligible(c.value, c.default_value)
    LOOP
        RAISE NOTICE 'core:V024 model/%: ungueltiger Wert "%" / Standard "%" bereinigt', r.key, r.value, r.default_value;
    END LOOP;
END $$;

UPDATE core.config c
   SET default_value = d.def,
       value = CASE WHEN core.fn_model_value_eligible(c.value, d.def) THEN c.value
                    ELSE coalesce(d.def, 'claude-sonnet-latest') END
  FROM (SELECT c2.id,
               CASE WHEN EXISTS (SELECT 1 FROM agent.ai_models m WHERE m.model_key = c2.default_value)
                    THEN c2.default_value END AS def
          FROM core.config c2 WHERE c2.category = 'model') d
 WHERE c.id = d.id
   AND c.category = 'model' AND NOT core.fn_model_value_eligible(c.value, c.default_value);

-- 3. Owner-Regel auf value + default_value
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT c.key, c.value FROM core.config c JOIN agent.ai_models m ON m.model_key = c.value
         WHERE c.category = 'model' AND m.provider = 'Google' AND m.mode = 'chat'
           AND c.value IS DISTINCT FROM c.default_value
    LOOP
        RAISE NOTICE 'core:V024 model/%: eigener Wert "%" (Gemini) wird auf Claude umgestellt', r.key, r.value;
    END LOOP;
END $$;

WITH gemini AS (
    SELECT model_key,
           CASE WHEN model_key = 'gemini-2.5-flash' THEN 'claude-haiku-latest' ELSE 'claude-sonnet-latest' END AS repl
      FROM agent.ai_models WHERE provider = 'Google' AND mode = 'chat'
)
UPDATE core.config c
   SET value         = coalesce((SELECT g.repl FROM gemini g WHERE g.model_key = c.value), c.value),
       default_value = coalesce((SELECT g.repl FROM gemini g WHERE g.model_key = c.default_value), c.default_value)
 WHERE c.category = 'model'
   AND (c.value IN (SELECT model_key FROM gemini) OR c.default_value IN (SELECT model_key FROM gemini));

-- 4. Gemini-Chat-Zeilen loeschen (Embeddings bleiben)
DELETE FROM agent.ai_models WHERE provider = 'Google' AND mode = 'chat';

-- 5. Fremdschluessel (geguardet: wiederholbar)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'core.config'::regclass AND conname = 'config_model_ref_fkey') THEN
        ALTER TABLE core.config ADD CONSTRAINT config_model_ref_fkey
            FOREIGN KEY (model_ref) REFERENCES agent.ai_models (model_key) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'core.config'::regclass AND conname = 'config_model_default_ref_fkey') THEN
        ALTER TABLE core.config ADD CONSTRAINT config_model_default_ref_fkey
            FOREIGN KEY (model_default_ref) REFERENCES agent.ai_models (model_key) ON DELETE RESTRICT;
    END IF;
END $$;
