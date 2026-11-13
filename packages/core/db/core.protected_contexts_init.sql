-- ============================================================
-- core.protected_contexts — paket-deklarierte Löschschutz-Registry
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.protected_contexts_init.sql
--
-- Zweck: Loeschschutz fuer agent.core_contexts ueber eine host-eigene Registry nach dem
--   Kubernetes-Finalizer/ownerReference-Muster (kein Name-Hardcode, kein mutables metadata.protected-Flag):
--   eine geschuetzte Zeile ist erst loeschbar, wenn ihr Registry-Eintrag entfernt ist — das tut
--   nur der Host (Installer/Deinstall), nie die Laufzeit. Der Lösch-Trigger
--   agent.trg_core_contexts_protect liest diese Tabelle (NEW.name -> EXISTS -> RAISE).
--
-- Boundary (Deklaration vs. Ausfuehrung, analog core.context_validators, docs/package-contract.md §3.4/§4):
--   das Paket deklariert die geschuetzten Context-Namen nur im manifest.json ("protected_contexts"-Liste);
--   der Host (seed_data.sh, jq) upsertet die Zeilen. Paket-Rollen (finance_rw/finance_ro) sind via D10
--   schema-isoliert und haben auf Schema core ueberhaupt keinen Zugriff -> koennen die Registry strukturell
--   nicht schreiben (= tamper-proof zur Laufzeit, ohne "Waechter-des-Waechters"-Trigger; kein REVOKE noetig,
--   PG grantet Tabellen nicht an PUBLIC). Einziger Schreiber = Installer/Owner-Superuser.
--
-- Ein Eintrag je Context (PRIMARY KEY); package = besitzendes Paket (Uninstall-Scope: --purge loescht
--   erst WHERE package='<pkg>' hier, dann die core_contexts-Zeilen).
--
-- Schema-Wahl "core": cross-cutting System-Infrastruktur (wie core.context_validators / core.config).
--   Diese Datei enthaelt nur das Schema; die Zeilen seedet seed_data.sh aus den Paket-Manifesten.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.protected_contexts (
    context_name text PRIMARY KEY,                 -- agent.core_contexts.name der geschuetzten Zeile
    package      text NOT NULL DEFAULT 'core',     -- deklarierendes/besitzendes Paket (Uninstall-Scope)
    updated_at   timestamptz NOT NULL DEFAULT now()
);
-- Kein updated_at-Touch-Trigger (analog core.context_validators): core.touch_updated_at lebt in
-- core.package_registry_init.sql (alphabetisch nach dieser Datei) -> der Seed setzt updated_at im
-- ON CONFLICT DO UPDATE explizit. Selten beschriebene Registry.
