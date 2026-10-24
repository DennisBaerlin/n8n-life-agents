-- ============================================================
-- V001 (core) — D14 / WS-B2: core_contexts.package + managed_by als TYPISIERTE Spalten.
--
-- WARUM: Bis hier lagen "besitzendes Paket" (Uninstall-Purge-Key) und "Sync-Provenienz"
--   (wer ueberschreibt die Zeile) als jsonb-Keys in metadata (metadata.package / .managed_by).
--   Beide sind query-tragende Invarianten (Seeder skippt managed_by='agent', fn_export_bundle
--   filtert darauf, der Uninstall-Purge loescht WHERE package='<pkg>'). Projekt-Gesetz
--   "Invarianten so tief wie moeglich" -> typisierte Spalten + CHECK statt jsonb-Keys.
--   (arch-challenge WS-B2: ADOPT Promotion; KEINE Umbenennung zu `origin` — managed_by
--    [Sync-Ownership] und monitor_triggers.origin [Authorship] sind verschiedene Achsen.)
--
-- Die SPALTEN legt agent.core_init.sql an (fresh: CREATE TABLE-Endzustand; Bestand:
--   ADD COLUMN IF NOT EXISTS + CHECK). Diese V-Migration macht den EINMALIGEN DATEN-Backfill
--   aus den Alt-metadata-Keys + entkoppelt sie (Strip). Idempotenz braucht sie nicht selbst
--   (ledger-gegated, laeuft genau einmal) — aber sie ist re-run-sicher: nach dem Strip liefert
--   metadata->>'managed_by' NULL -> COALESCE haelt den Spaltenwert.
--
-- Reihenfolge (Apply): Baseline-Inits (Spalten da) -> DIESE V001 -> R__ -> util.
--   Fresh-DB: core_contexts ist hier noch LEER (seed_data laeuft erst NACH apply_schema) ->
--   die UPDATEs treffen 0 Zeilen; seed_data schreibt die Spalten dann direkt.
--   Bestands-DB (lifeagents update): die Alt-Zeilen tragen metadata.managed_by/.package -> Backfill.
-- ============================================================

-- (1) Backfill aus den Alt-metadata-Keys (Spalten-Defaults 'core'/'seed' bleiben, wo kein Key war).
UPDATE agent.core_contexts
   SET managed_by = COALESCE(NULLIF(metadata->>'managed_by', ''), managed_by),
       package    = COALESCE(NULLIF(metadata->>'package', ''),    package);

-- (2) Paket-besessene Laufzeit-Zeilen (D12): finance_profile + der advisor-publizierte finance-Plan
--     tragen KEIN metadata.package (sie entstehen zur Laufzeit via Skelett-Seed / Publish, nicht via
--     seed_data) -> explizit auf 'finance' heben. family bleibt 'core' (Haushalt = Core-Domaene).
UPDATE agent.core_contexts SET package = 'finance' WHERE name IN ('finance_profile', 'finance_plan_current');

-- (3) Entkoppeln: die promoteten Keys aus metadata entfernen (eine Quelle = die Spalten).
--     protected/facts/render_fn/domain/version/... bleiben unangetastet.
UPDATE agent.core_contexts
   SET metadata = metadata - 'managed_by' - 'package'
 WHERE metadata ?| array['managed_by', 'package'];
