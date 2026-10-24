-- tests/db/paperless/test_paperless_retire.sql
-- Phase 1 (Plan quiet-watching-meadow): paperless:V001 baut die alte Dokumenten-Pipeline auf Bestands-
-- Installationen zurueck. Der Test baut den v0.2.0-Altbestand minimal nach (Tabellen inkl. halfvec-Spalte,
-- die 10 Pipeline-fns, Config-Zeilen, geschuetzte Prompt-Contexts, Alert-Latches, reset-skip-Marker,
-- R__-Ledger-Zeilen), fuehrt die ECHTE Migrationsdatei aus (\ir, keine Kopie -> kein Drift) und prueft:
--   (1) alles Pipeline-Eigene ist weg (inkl. pgvector im Paket-Schema),
--   (2) Bleibendes bleibt: general.paperless_url, fremde Config/Contexts/Latches, fn_clear_e2e_data, Schema,
--   (3) ein zweiter Lauf ist ein No-op (idempotent).
-- Die pgvector-Teile laufen nur, wenn das Test-Image die Extension anbietet (sonst NOTICE + Rest-Pruefung).
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

ALTER TABLE core.config DISABLE TRIGGER trg_config_check_model_value;   -- Modell-Enum ist hier nicht Pruefgegenstand

DO $$
DECLARE
  v_vec boolean := EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector');
  v_fn  text;
BEGIN
  -- ---------- Altbestand nachbauen ----------
  IF v_vec AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
    CREATE EXTENSION vector WITH SCHEMA paperless;
  END IF;
  CREATE OR REPLACE FUNCTION paperless.touch_updated_at() RETURNS trigger LANGUAGE plpgsql
    AS 'BEGIN NEW.updated_at := now(); RETURN NEW; END';
  CREATE TABLE IF NOT EXISTS paperless.documents (doc_id bigint PRIMARY KEY, updated_at timestamptz NOT NULL DEFAULT now());
  DROP TRIGGER IF EXISTS trg_documents_touch ON paperless.documents;
  CREATE TRIGGER trg_documents_touch BEFORE UPDATE ON paperless.documents
    FOR EACH ROW EXECUTE FUNCTION paperless.touch_updated_at();
  IF v_vec AND EXISTS (SELECT 1 FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
                        WHERE e.extname = 'vector' AND n.nspname = 'paperless') THEN
    EXECUTE 'CREATE TABLE IF NOT EXISTS paperless.document_chunks (id bigint PRIMARY KEY, '
         || 'doc_id bigint NOT NULL REFERENCES paperless.documents (doc_id) ON DELETE CASCADE, '
         || 'embedding paperless.halfvec(3) NOT NULL)';
  ELSE
    CREATE TABLE IF NOT EXISTS paperless.document_chunks (id bigint PRIMARY KEY,
      doc_id bigint NOT NULL REFERENCES paperless.documents (doc_id) ON DELETE CASCADE);
  END IF;
  CREATE TABLE IF NOT EXISTS paperless.sync_state (id int PRIMARY KEY DEFAULT 1 CHECK (id = 1));
  INSERT INTO paperless.documents (doc_id) VALUES (1) ON CONFLICT DO NOTHING;
  INSERT INTO paperless.sync_state (id) VALUES (1) ON CONFLICT DO NOTHING;
  FOREACH v_fn IN ARRAY ARRAY['fn_checkpoint_ocr', 'fn_claim_document', 'fn_delete_document', 'fn_index_document',
                              'fn_mark_error', 'fn_release_document', 'fn_search_chunks', 'fn_set_metadata',
                              'fn_set_sync_state', 'fn_upsert_document'] LOOP
    EXECUTE format('CREATE OR REPLACE FUNCTION paperless.%I(p jsonb) RETURNS jsonb LANGUAGE sql AS %L', v_fn, 'SELECT p');
  END LOOP;
  COMMENT ON SCHEMA paperless IS 'lifecycle:reset-skip - Altbestand';

  INSERT INTO core.config (category, key, value, package) VALUES
    ('model', 'doc_metadata', 'claude-haiku-latest', 'paperless'), ('schedule', 'reconcile', '*/10 * * * *', 'paperless'),
    ('cron_enable', 'reconcile', 'true', 'paperless'), ('general', 'gcp_project_id', 'p', 'paperless'),
    ('general', 'gcp_location', 'eu', 'paperless'), ('general', 'docai_processor_id', 'x', 'paperless'),
    ('general', 'language', 'German', 'paperless'), ('general', 'create_new_tags', 'false', 'paperless'),
    ('general', 'correspondent_blacklist', '', 'paperless'), ('general', 'remove_content_regex', '', 'paperless'),
    ('general', 'tag_skip', 'paperless-skip', 'paperless'), ('general', 'tag_failed', 'paperless-failed', 'paperless'),
    ('general', 'paperless_url', 'http://paperless.lan:8000', 'paperless'),
    ('model', 'paperless_assistant', 'claude-haiku-latest', 'paperless'),   -- lebende v0.4.0-Config: muss bleiben
    ('general', 'zz_retire_foreign', 'bleibt', 'finance')
  ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value, package = EXCLUDED.package;

  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package)
  SELECT n, 'prompt', 'lazy', 'owner-edited', 'agent', 'paperless'
    FROM unnest(ARRAY['paperless_prompt_title', 'paperless_prompt_tags', 'paperless_prompt_correspondent',
                      'paperless_prompt_document_type', 'paperless_prompt_created_date',
                      'paperless_prompt_custom_fields', 'paperless_prompt_ocr']) n
  ON CONFLICT (name) DO UPDATE SET package = 'paperless';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package)
  VALUES ('zz_retire_other', 'bleibt', 'lazy', 'x', 'agent', 'paperless')
  ON CONFLICT (name) DO NOTHING;
  INSERT INTO core.protected_contexts (context_name, package)
  SELECT n, 'paperless'
    FROM unnest(ARRAY['paperless_prompt_title', 'paperless_prompt_tags', 'paperless_prompt_correspondent',
                      'paperless_prompt_document_type', 'paperless_prompt_created_date',
                      'paperless_prompt_custom_fields', 'paperless_prompt_ocr', 'zz_retire_other']) n
  ON CONFLICT (context_name) DO NOTHING;

  INSERT INTO core.notification_state (source, key) VALUES
    ('paperless:pipeline', '42'), ('paperless:auth', 'token'), ('finance', 'zz_retire')
  ON CONFLICT (source, key) DO NOTHING;

  -- Ledger-Form EXAKT wie der Treiber sie schreibt (core.repeatable_should_apply: version = filename = relativer Pfad)
  INSERT INTO core.schema_version (version, filename, kind, package) VALUES
    ('packages/paperless/db/migrations/R__fn_claim_document.sql', 'packages/paperless/db/migrations/R__fn_claim_document.sql', 'repeatable', 'paperless'),
    ('packages/paperless/db/migrations/R__fn_search_chunks.sql', 'packages/paperless/db/migrations/R__fn_search_chunks.sql', 'repeatable', 'paperless'),
    ('packages/paperless/db/migrations/R__fn_clear_e2e_data.sql', 'packages/paperless/db/migrations/R__fn_clear_e2e_data.sql', 'repeatable', 'paperless')
  ON CONFLICT (version) DO NOTHING;
END $$;

-- ---------- die ECHTE Migration (zweimal: Idempotenz) ----------
\ir ../../../packages/paperless/db/migrations/V001__retire_pipeline.sql
\ir ../../../packages/paperless/db/migrations/V001__retire_pipeline.sql

DO $$
BEGIN
  -- (1) weg
  IF to_regclass('paperless.documents') IS NOT NULL OR to_regclass('paperless.document_chunks') IS NOT NULL
     OR to_regclass('paperless.sync_state') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (1) Pipeline-Tabellen noch da';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'paperless' AND p.proname <> 'fn_clear_e2e_data') THEN
    RAISE EXCEPTION 'FAIL (1) Pipeline-fns noch da: %', (SELECT string_agg(p.proname, ', ') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'paperless' AND p.proname <> 'fn_clear_e2e_data');
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
              WHERE e.extname = 'vector' AND n.nspname = 'paperless') THEN
    RAISE EXCEPTION 'FAIL (1) pgvector im Paket-Schema noch da';
  END IF;
  -- Genau die zurueckgebauten Pipeline-Keys (dieselbe explizite Liste wie V001); seit v0.4.0 lebt daneben legitim
  -- neue paperless-Config (model.paperless_assistant), die V001 NIE anfassen darf (Pruefung unter (2)).
  IF EXISTS (SELECT 1 FROM core.config WHERE package = 'paperless' AND (category, key) IN (
               ('model', 'doc_metadata'), ('schedule', 'reconcile'), ('cron_enable', 'reconcile'),
               ('general', 'gcp_project_id'), ('general', 'gcp_location'), ('general', 'docai_processor_id'),
               ('general', 'language'), ('general', 'create_new_tags'), ('general', 'correspondent_blacklist'),
               ('general', 'remove_content_regex'), ('general', 'tag_skip'), ('general', 'tag_failed'))) THEN
    RAISE EXCEPTION 'FAIL (1) Pipeline-Config noch da: %', (SELECT string_agg(category || '.' || key, ', ')
      FROM core.config WHERE package = 'paperless' AND key <> 'paperless_url');
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name LIKE 'paperless\_prompt\_%')
     OR EXISTS (SELECT 1 FROM core.protected_contexts WHERE context_name LIKE 'paperless\_prompt\_%') THEN
    RAISE EXCEPTION 'FAIL (1) Prompt-Contexts/Loeschschutz noch da';
  END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source IN ('paperless:pipeline', 'paperless:auth')) THEN
    RAISE EXCEPTION 'FAIL (1) Pipeline-Latches noch da';
  END IF;
  IF COALESCE(obj_description(to_regnamespace('paperless')::oid, 'pg_namespace'), '') LIKE 'lifecycle:reset-skip%' THEN
    RAISE EXCEPTION 'FAIL (1) reset-skip-Marker noch da';
  END IF;
  IF EXISTS (SELECT 1 FROM core.schema_version WHERE package = 'paperless' AND version IN
             ('packages/paperless/db/migrations/R__fn_claim_document.sql', 'packages/paperless/db/migrations/R__fn_search_chunks.sql')) THEN
    RAISE EXCEPTION 'FAIL (1) verwaiste R__-Ledger-Zeilen noch da';
  END IF;

  -- (2) bleibt
  IF to_regnamespace('paperless') IS NULL OR to_regprocedure('paperless.fn_clear_e2e_data(text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL (2) Schema/fn_clear_e2e_data mitentfernt';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.schema_version WHERE version = 'packages/paperless/db/migrations/R__fn_clear_e2e_data.sql') THEN
    RAISE EXCEPTION 'FAIL (2) Ledger-Zeile des lebenden R__fn_clear_e2e_data mitentfernt';
  END IF;
  IF (SELECT value FROM core.config WHERE category = 'general' AND key = 'paperless_url') IS DISTINCT FROM 'http://paperless.lan:8000'
     OR NOT EXISTS (SELECT 1 FROM core.config WHERE key = 'zz_retire_foreign') THEN
    RAISE EXCEPTION 'FAIL (2) paperless_url/fremde Config angefasst';
  END IF;
  -- Lebende v0.4.0-Config (oben im Altbestand mit angelegt) ueberlebt den Rueckbau (explizite Liste in V001).
  IF NOT EXISTS (SELECT 1 FROM core.config WHERE package = 'paperless' AND category = 'model' AND key = 'paperless_assistant') THEN
    RAISE EXCEPTION 'FAIL (2) lebende Config model.paperless_assistant mitentfernt';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = 'zz_retire_other')
     OR NOT EXISTS (SELECT 1 FROM core.protected_contexts WHERE context_name = 'zz_retire_other') THEN
    RAISE EXCEPTION 'FAIL (2) nicht gelisteter paperless-Context/Loeschschutz angefasst';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance' AND key = 'zz_retire') THEN
    RAISE EXCEPTION 'FAIL (2) fremder Latch angefasst';
  END IF;
  RAISE NOTICE 'PASS paperless:V001 Rueckbau (2 Laeufe, Altbestand weg, Rest unberuehrt)';
END $$;

ROLLBACK;
