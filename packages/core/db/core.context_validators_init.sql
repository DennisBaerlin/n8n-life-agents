-- ============================================================
-- core.context_validators — generische Validator-Registry (WS-B1 / D12)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.context_validators_init.sql
--
-- Zweck: bindet einen paket-besessenen Sidecar-Context-Namen (z. B. 'finance_profile')
--   an die PAKET-Validator-fn, die seine metadata.facts-Struktur prueft. Der Core-Trigger
--   agent.trg_core_contexts_validate_facts_fn dispatcht GENERISCH ueber diese Tabelle
--   (NEW.name -> validate_fn -> dyn. EXECUTE) — der Core nennt KEIN Paket mehr hartkodiert
--   (ersetzt den fruehen to_regprocedure('finance.fn_validate_finance_profile')-Hardcode aus 8c4000f).
--
-- BOUNDARY (Deklaration vs. Ausfuehrung, docs/package-contract.md §3.3): das PAKET DEKLARIERT
--   die Bindung NUR im manifest.json ("context_validators"-Block); der HOST (seed_data.sh, jq)
--   UPSERTET die Zeile. Paket-Rollen (finance_rw/finance_ro) sind via D10 schema-isoliert und haben
--   auf Schema core ueberhaupt KEINEN Zugriff -> koennen die Registry strukturell nicht schreiben
--   (kein REVOKE noetig: PG grantet Tabellen ohnehin nicht an PUBLIC; der einzige Schreiber ist der
--   Installer/Owner-Superuser). seed_data prueft zusaetzlich, dass validate_fn ins EIGENE Paket-Schema
--   zeigt (ein Paket bindet nur <pkg>.* — own-schema-scoping wie bei den Rollen-Grants).
--
-- EIN Validator je Context (PRIMARY KEY): das erste Paket gewinnt; ein Zweit-Paket, das denselben
--   Context-Namen binden will, kollidiert beim Seed (ON CONFLICT sichtbar) statt still zu ueberschreiben.
--
-- SICHERHEIT (dyn. SQL im Trigger, CVE-2018-1058): validate_fn ist NUR installer-geschrieben (nie
--   $fromAI/User-Input). Der CHECK erzwingt einen schema-qualifizierten, kleingeschriebenen Bezeichner
--   ohne Injection-Zeichen; der Trigger pinnt search_path=pg_catalog + ruft den voll qualifizierten Namen.
--
-- Schema-Wahl "core": cross-cutting System-Infrastruktur (wie core.config / core.package_registry),
--   kein Agenten-Belang. Diese Datei enthaelt nur das SCHEMA; die Zeilen seedet seed_data.sh aus den
--   Paket-Manifesten.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.context_validators (
    context_name text PRIMARY KEY,                 -- agent.core_contexts.name des paket-besessenen Sidecars (z. B. 'finance_profile')
    validate_fn  text NOT NULL                     -- schema-qualifizierte fn(jsonb)->text; NULL=gueltig, sonst Fehlertext
                 CHECK (validate_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),  -- schema.fn, lowercase, fuehrender Buchstabe, kein Injection-Zeichen (wie der Onboarding-Name-Regex)
    package      text NOT NULL DEFAULT '',         -- deklarierendes Paket (Audit / Uninstall-Scope)
    updated_at   timestamptz NOT NULL DEFAULT now()
);
-- KEIN updated_at-Touch-Trigger: core.touch_updated_at lebt in core.package_registry_init.sql, das
-- ALPHABETISCH NACH dieser Datei applied wird (CREATE TRIGGER wuerde die fn noch nicht finden). Der
-- Seed setzt updated_at im ON CONFLICT DO UPDATE explizit -> kein Trigger noetig (selten beschriebene Registry).
