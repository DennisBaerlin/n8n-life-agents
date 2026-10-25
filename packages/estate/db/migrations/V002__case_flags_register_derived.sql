-- ============================================================
-- V002 (estate) -- WP3 "Ableitbares wird nie gespeichert": Bestand an die neuen Fall-/Register-Regeln angleichen.
--
--   (1) cases.flags: das alte tool_create_case schrieb IMMER alle sechs Merkmale (unbeantwortet = false). Ab WP3
--       speichert der Fall nur Nutzer-Aussagen und leitet den Rest aus dem Register ab (fn_case_register_flags);
--       ein Alt-false wuerde die Ableitung still ueberstimmen. Darum alle false-Werte entfernen (das waren Defaults,
--       keine Antworten); true bleibt (das hat der Agent erfragt).
--   (2) case_tasks.status_source (Init-Spalte, Default 'system'): wer hat den Status gesetzt? Der Reconcile zieht
--       nur 'system'-Zeilen nach. Im Bestand rekonstruiert:
--         * done                                   -> 'user' (nur fn_set_case_task setzt done)
--         * not_applicable ohne Bedingung          -> 'user' (der Soll-Satz setzt sie nie n.a. -> per Knopf)
--         * not_applicable, Merkmal steht auf true  -> 'user' (der Soll-Satz haette sie geoeffnet)
--         * alles andere                           -> 'system'
--   (3) case_tasks: done_at gehoert genau zu status='done' (Backfill, dann CHECK, wie im Init-CREATE).
--   (4) funeral_preferences: ein Anbieter heisst "Vorsorgevertrag vorhanden" (Backfill -> true, auch bei einem
--       widerspruechlichen false: der Anbieter-Name ist der staerkere Beleg und geht so nicht verloren), dann CHECK.
--   (5) estate.onboarding_state.skipped_at: ungenutzt, ableitbar aus status + status_changed_at -> drop.
--
--   Guards: CHECKs nur, wenn noch nicht vorhanden (frischer Install traegt sie schon aus dem Init-CREATE).
-- APPLY-ORDER: Inits -> V (hier) -> R -> Seed.
-- ============================================================

-- (1) Alt-Defaults aus den Fall-Merkmalen entfernen
UPDATE estate.cases AS cs
   SET flags = (SELECT coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb)
                  FROM jsonb_each(cs.flags) AS e (k, v) WHERE e.v <> 'false'::jsonb)
 WHERE EXISTS (SELECT 1 FROM jsonb_each(cs.flags) AS e (k, v) WHERE e.v = 'false'::jsonb);

-- (2) Provenienz der Bestands-Status
UPDATE estate.case_tasks AS ct
   SET status_source = 'user'
  FROM estate.cases AS c
 WHERE c.id = ct.case_id
   AND (ct.status = 'done'
        OR (ct.status = 'not_applicable'
            AND (ct.template_key IS NULL
                 OR NOT EXISTS (SELECT 1 FROM estate.task_templates t
                                 WHERE t.template_key = ct.template_key AND t.condition_key IS NOT NULL)
                 OR EXISTS (SELECT 1 FROM estate.task_templates AS t
                             INNER JOIN estate.cases AS c2 ON c2.id = ct.case_id
                             WHERE t.template_key = ct.template_key
                               AND c2.flags ->> t.condition_key = 'true'))));

-- (3) done_at <-> done
UPDATE estate.case_tasks SET done_at = updated_at WHERE status = 'done' AND done_at IS NULL;
UPDATE estate.case_tasks SET done_at = NULL WHERE status <> 'done' AND done_at IS NOT NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'case_tasks_done_at_consistency'
                      AND conrelid = 'estate.case_tasks'::regclass) THEN
        ALTER TABLE estate.case_tasks ADD CONSTRAINT case_tasks_done_at_consistency
            CHECK ((status = 'done') = (done_at IS NOT NULL));
    END IF;
END $$;

-- (4) Anbieter => Vorsorgevertrag
UPDATE estate.funeral_preferences
   SET has_prepaid_contract = TRUE
 WHERE prepaid_contract_provider IS NOT NULL AND has_prepaid_contract IS DISTINCT FROM TRUE;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'funeral_preferences_provider_implies_contract'
                      AND conrelid = 'estate.funeral_preferences'::regclass) THEN
        ALTER TABLE estate.funeral_preferences ADD CONSTRAINT funeral_preferences_provider_implies_contract
            CHECK (prepaid_contract_provider IS NULL OR has_prepaid_contract IS TRUE);
    END IF;
END $$;

-- (5) ableitbare Onboarding-Spalte
ALTER TABLE estate.onboarding_state DROP COLUMN IF EXISTS skipped_at;
