-- ============================================================
-- V001 (paperless) — die eigene Dokumenten-Pipeline (WS-0/WS-1) HART zurueckbauen.
--
--   WARUM: das Paket wird zum schlanken LESE-Zugang auf eine bestehende Paperless-NGX-Instanz (v3 bringt
--   eigene KI/Embeddings/Dokumenten-Chat mit; Ingest + Metadaten macht der Owner mit paperless-gpt).
--   Status-Maschine, Chunk-/Embedding-Store, Backfill-Cursor, Pipeline-fns, Prompt-Contexts und die
--   Pipeline-Config sind damit toter Bestand. Plan ~/.claude/plans/quiet-watching-meadow.md (Phase 1).
--
--   WARUM eine V-Migration: das Baseline-Init ist IF-NOT-EXISTS-additiv, R__-Dateien sind create-or-
--   replace, Seeds loeschen nie (fn_config_seed = Upsert) -> ohne diesen Schritt blieben auf Bestands-
--   Installationen alle Objekte + Zeilen als Leichen liegen (Praezedenz core V005/V007/V011).
--
--   CHIRURGISCH (alles ueber explizite Namenslisten, nie paketweit):
--     (1) die 10 Pipeline-fns, (2) die 3 Tabellen + den Touch-Trigger-Helfer, (3) die pgvector-Extension
--         NUR wenn sie im Schema paperless liegt (ownership-scoped; ein fremder vector-Konsument bleibt),
--     (4) die Pipeline-Config-Zeilen (general.paperless_url BLEIBT), (5) Loeschschutz DANN die 7 Prompt-
--         Contexts (der Delete-Trigger liest core.protected_contexts), (6) die Alert-Latches der Pipeline,
--     (7) den reset-skip-Marker des Schemas (es haelt keinen Cache mehr), (8) die verwaisten R__-Ledger-Zeilen.
--     Das Schema paperless selbst + paperless.fn_clear_e2e_data bleiben (Paket-Vertrag: Rolle paperless_ro
--     liest die URL-Config, Test-Cleanup-Hook).
--
--   IDEMPOTENT: alles IF EXISTS / WHERE-geguardet; Frisch-Install = No-op (dort entstand nichts davon).
--   Laeuft als Superuser im Apply-Treiber (eine Transaktion). Test: tests/db/paperless/test_paperless_retire.sql
--   fuehrt GENAU diese Datei auf einem nachgebauten Altbestand aus.
-- APPLY-ORDER: Inits -> V (hier) -> R.
-- ============================================================

-- (1) Pipeline-fns (Signaturen exakt; alle (p jsonb))
DROP FUNCTION IF EXISTS paperless.fn_checkpoint_ocr(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_claim_document(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_delete_document(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_index_document(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_mark_error(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_release_document(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_search_chunks(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_set_metadata(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_set_sync_state(jsonb);
DROP FUNCTION IF EXISTS paperless.fn_upsert_document(jsonb);

-- (2) Tabellen (Kind vor Eltern: document_chunks referenziert documents), dann der Trigger-Helfer
DROP TABLE IF EXISTS paperless.document_chunks;
DROP TABLE IF EXISTS paperless.documents;
DROP TABLE IF EXISTS paperless.sync_state;
DROP FUNCTION IF EXISTS paperless.touch_updated_at();

-- (3) pgvector — nur die Instanz im Paket-Schema (nach (2) ohne Abhaengige)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
                WHERE e.extname = 'vector' AND n.nspname = 'paperless') THEN
        DROP EXTENSION vector;
    END IF;
END $$;

-- (4) Pipeline-Config (Manifest deklariert sie nicht mehr; der Seed loescht nie)
DELETE FROM core.config
 WHERE package = 'paperless'
   AND (category, key) IN (('model', 'doc_metadata'), ('schedule', 'reconcile'), ('cron_enable', 'reconcile'),
                           ('general', 'gcp_project_id'), ('general', 'gcp_location'),
                           ('general', 'docai_processor_id'), ('general', 'language'),
                           ('general', 'create_new_tags'), ('general', 'correspondent_blacklist'),
                           ('general', 'remove_content_regex'), ('general', 'tag_skip'), ('general', 'tag_failed'));

-- (5) Prompt-Contexts: erst der Loeschschutz, dann die Zeilen (Finalizer-Reihenfolge wie fn_pkg_purge_data)
DELETE FROM core.protected_contexts
 WHERE package = 'paperless'
   AND context_name IN ('paperless_prompt_title', 'paperless_prompt_tags', 'paperless_prompt_correspondent',
                        'paperless_prompt_document_type', 'paperless_prompt_created_date',
                        'paperless_prompt_custom_fields', 'paperless_prompt_ocr');
DELETE FROM agent.core_contexts
 WHERE package = 'paperless'
   AND name IN ('paperless_prompt_title', 'paperless_prompt_tags', 'paperless_prompt_correspondent',
                'paperless_prompt_document_type', 'paperless_prompt_created_date',
                'paperless_prompt_custom_fields', 'paperless_prompt_ocr');

-- (6) Alert-Latches der Pipeline (fn_mark_error -> 'paperless:pipeline', Reconcile-Auth -> 'paperless:auth')
DELETE FROM core.notification_state WHERE source IN ('paperless:pipeline', 'paperless:auth');

-- (7) reset-skip-Marker: das Schema haelt keinen abgeleiteten Cache mehr
DO $$
BEGIN
    IF to_regnamespace('paperless') IS NOT NULL
       AND COALESCE(obj_description(to_regnamespace('paperless')::oid, 'pg_namespace'), '') LIKE 'lifecycle:reset-skip%' THEN
        COMMENT ON SCHEMA paperless IS NULL;
    END IF;
END $$;

-- (8) Verwaiste Repeatable-Ledger-Zeilen der geloeschten R__-Dateien (kosmetisch, Praezedenz core V011)
-- Der Treiber schreibt version = filename = relativer Pfad (core.repeatable_should_apply) -> Abgleich auf version.
DELETE FROM core.schema_version
 WHERE package = 'paperless' AND kind = 'repeatable'
   AND version IN (SELECT 'packages/paperless/db/migrations/R__' || f || '.sql'
                     FROM unnest(ARRAY['fn_checkpoint_ocr', 'fn_claim_document', 'fn_delete_document', 'fn_index_document',
                                       'fn_mark_error', 'fn_release_document', 'fn_search_chunks', 'fn_set_metadata',
                                       'fn_set_sync_state', 'fn_upsert_document']) f);
