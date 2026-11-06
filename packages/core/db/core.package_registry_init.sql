-- ============================================================
-- core.package_registry + core.services — Core-Paket-Framework (Phase 1)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.package_registry_init.sql
--
-- Zweck: Die DB-Wahrheit der paketbasierten Core/Package-Architektur (Plan
--   tender-stargazing-shannon §5.3/§5.5). Pakete (Fach-Domaenen wie 'finance')
--   werden ueber die CLI installiert/aktiviert/deaktiviert/deinstalliert; ihr
--   Lebenszyklus-Status lebt hier — der Orchestrator-Deploy materialisiert die
--   Routen aus `status='active'`, der Runtime-Pre-Router kappt deaktivierte.
--
-- Schema-Wahl "core": genuin cross-cutting System-Infrastruktur (wie core.config /
--   core.schema_version), kein Agenten-Belang. Der Core selbst ist als Paket
--   ('core', immer active) modelliert (homogene Behandlung).
--
-- ZWEI Tabellen:
--   1. package_registry — Installations-/Status-Wahrheit je Paket (Lifecycle).
--   2. services          — logische Service-Alias-Map (D9): logischer Name
--      ('human_approval', 'web_search', …) -> physische n8n-Workflow-id (+ besitzendes
--      `package`). DECLARED state: `seed_data` materialisiert die Zeilen generisch aus
--      `provides.services` ALLER Paket-Manifeste (WS-B6 _seed_services), die Deploy-Existenz
--      bestaetigt die Verifikation post-deploy. Die BUILD-ZEIT-Aufloesung von
--      `core:<name>` -> Workflow laeuft NICHT ueber diese Tabelle (build.ps1 hat
--      keinen DB-Zugriff), sondern ueber das Manifest `provides.services`
--      (Alias->Name) + den getrackten Datei-State (Name->id).
--
-- Diese Datei enthaelt nur das SCHEMA. Registry-Zeilen entstehen zur Laufzeit
--   ueber die CLI (fn_pkg_*); services-Zeilen materialisiert `seed_data` (WS-B6).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

-- Generischer updated_at-Touch (core-weit; eigene Funktion, damit core nicht von
-- agent.touch_updated_at abhaengt — Schicht-Sauberkeit).
CREATE OR REPLACE FUNCTION core.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- core.package_registry — eine Zeile je installiertem Paket.
--   status-Lebenszyklus: installing -> installed -> active <-> inactive.
--     installing = Migration/Deploy laeuft (Teil-Install sichtbar, R7);
--     installed  = DB/Workflows da, aber nicht verdrahtet;
--     active      = verdrahtet + geroutet;
--     inactive    = deaktiviert (Daten bleiben! nur Pre-Router-Gate kappt).
--   `active` wird IMMER zuletzt gesetzt (atomarer Konvergenz-Deploy).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.package_registry (
    package             text PRIMARY KEY,                         -- Paketname = Schema-Name (z. B. 'finance', 'core')
    version             text        NOT NULL DEFAULT '',          -- SemVer des installierten Pakets
    description         text        NOT NULL DEFAULT '',          -- fuer `lifeagents package catalog`
    status              text        NOT NULL DEFAULT 'installing'
                        CHECK (status IN ('installing','installed','active','inactive')),
    core_api_at_install text        NOT NULL DEFAULT '',          -- die vom Paket geforderte core_api-Mindestversion (Audit/Re-Check)
    requires            text[]      NOT NULL DEFAULT '{}',        -- Paket-Abhaengigkeiten (Dep-Graph)
    manifest_checksum   text        NOT NULL DEFAULT '',          -- md5 des Manifests (Drift/Update-Erkennung)
    installed_at        timestamptz NOT NULL DEFAULT now(),
    activated_at        timestamptz,                              -- erstmals/zuletzt aktiviert (NULL = nie aktiv)
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- CC1-Aufraeumung (WS4a-WP1): die fruehe `config jsonb`-Spalte ("paket-isolierte Config") war ungenutzt
-- (kein Konsument: fn_pkg_register schreibt sie nie, export_bundle exportiert package_registry nicht). Die
-- per-Paket-Config lebt jetzt in core.config (+ package-Spalte), deklariert im Manifest (Sibling-Registry-
-- Konvention). Spalte additiv-idempotent entfernen (leer -> kein Rewrite); KEINE V-Migration.
ALTER TABLE core.package_registry DROP COLUMN IF EXISTS config;

-- Install-UX-Phase 6: deutscher Anzeigename (Manifest `display_name`, von fn_pkg_register kopiert wie
-- `description` — Quelle bleibt das Manifest) fuer die Owner-Begruessung (core.fn_render_welcome).
-- Additiv-idempotent (Init-only, Muster core.services.package; leerer Default = Paketname-Fallback).
ALTER TABLE core.package_registry ADD COLUMN IF NOT EXISTS display_name text NOT NULL DEFAULT '';

DROP TRIGGER IF EXISTS trg_package_registry_touch ON core.package_registry;
CREATE TRIGGER trg_package_registry_touch
    BEFORE UPDATE ON core.package_registry
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();

-- ------------------------------------------------------------
-- core.services — logische Service-Alias-Map (D9), DECLARED state.
--   `name` = logischer Core-Dienst (ohne 'core:'-Praefix), z. B. 'human_approval'.
--   `workflow_id` = die physische n8n-Workflow-id. `seed_data` materialisiert sie (declared,
--      generisch ueber alle Paket-Manifeste, WS-B6 _seed_services); die tatsaechliche Deploy-Existenz
--      bestaetigt die Verifikation (workflow_entity-Abgleich) post-deploy.
--   `package` = besitzendes/deklarierendes Paket (Audit/Uninstall-Scope).
--   Build-Zeit-Aufloesung von `core:<name>` laeuft ueber das Manifest, NICHT hier
--   (build.ps1 hat keinen DB-Zugriff) — s. Kopf-Kommentar.
--
-- Geguardeter Rename (WS-B4, Stutter-Entfernung core.core_services -> core.services;
--   etabliertes Idiom, .claude/rules/sql.md *Schema-Aenderungs-Regeln*): Bestands-DB ->
--   ALTER RENAME (Daten/Constraints folgen), Fresh-DB -> no-op, dann CREATE-Endzustand.
-- ------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('core.core_services') IS NOT NULL AND to_regclass('core.services') IS NULL THEN
        ALTER TABLE core.core_services RENAME TO services;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS core.services (
    name        text PRIMARY KEY,                 -- logischer Dienstname (z. B. 'human_approval', 'web_search')
    workflow_id text        NOT NULL DEFAULT '',   -- physische n8n-Workflow-id (seed_data materialisiert, WS-B6)
    description text        NOT NULL DEFAULT '',   -- optionaler Freitext (NICHT der Workflow-Name — der ist via workflow_entity ableitbar)
    package     text        NOT NULL DEFAULT 'core', -- besitzendes/deklarierendes Paket (Audit/Uninstall-Scope, analog core.protected_contexts; WS-B6)
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Bestehende DBs (services evtl. schon ohne package angelegt): Spalte nachziehen (additiv, leer ->
-- kein Table-Rewrite). Idiom wie core.schema_version (CREATE TABLE-Endzustand + ALTER ADD COLUMN
-- IF NOT EXISTS), NICHT eine V-Migration — additive Spalte, kein Backfill/destruktiv (.claude/rules/sql.md
-- *Migrations-Modell*). WS-B6.
ALTER TABLE core.services ADD COLUMN IF NOT EXISTS package text NOT NULL DEFAULT 'core';

-- Paket-Tool-Services (paperless Phase 2, docs/package-contract.md §5): ein Nicht-Core-Paket stellt Werkzeuge
-- fuer fremde Agenten bereit; Name in dieser Tabelle QUALIFIZIERT '<package>:<alias>' (globaler PK -> keine
-- Kollision zwischen Anbietern), Core-Zeilen bleiben unqualifiziert. `permission` = wer das Werkzeug ueber den
-- Vermittler agent.sub_dispatch_tool nutzen darf; Entscheidung in core.fn_resolve_service (PDP). Default
-- 'owner_only' = fail-closed (Paritaet core.callback_handlers.member_permeable DEFAULT false); der Seeder
-- schreibt den Manifest-Wert. Additiv (Bestand = nur Core-Zeilen, erfuellen beide CHECKs) -> Init-Idiom, keine V-Migration.
ALTER TABLE core.services ADD COLUMN IF NOT EXISTS permission text NOT NULL DEFAULT 'owner_only';
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'services_permission_check') THEN
        ALTER TABLE core.services ADD CONSTRAINT services_permission_check
            CHECK (permission IN ('all_members', 'adults_only', 'owner_only'));
    END IF;
    -- Namens-Praefix = besitzendes Paket (DB-Backstop: der Vermittler loest '<pkg>:<alias>' auf und darf nie
    -- eine Zeile eines ANDEREN Pakets unter diesem Praefix treffen).
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'services_name_package_check') THEN
        ALTER TABLE core.services ADD CONSTRAINT services_name_package_check
            CHECK ((package = 'core' AND strpos(name, ':') = 0)
                OR (package <> 'core' AND left(name, length(package) + 1) = package || ':'
                    AND length(name) > length(package) + 1));
    END IF;
END $$;

DROP TRIGGER IF EXISTS trg_core_services_touch ON core.services;
DROP TRIGGER IF EXISTS trg_services_touch ON core.services;
CREATE TRIGGER trg_services_touch
    BEFORE UPDATE ON core.services
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();
