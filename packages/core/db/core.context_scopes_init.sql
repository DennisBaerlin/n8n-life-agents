-- ============================================================
-- core.context_scopes — generische Scope-/Permission-Registry (P0a, deklaratives Fundament)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.context_scopes_init.sql
--
-- Zweck: deklariert je facts-Context-Namen ZWEI orthogonale Achsen, getrennt von der
--   approval_matrix (die regelt WIE bestaetigt wird — HITL-Flow je Gate-Aufrufer):
--     scope            = ob der Context HAUSHALTSWEIT (household) oder PRO PERSON (per_user) lebt;
--     write_permission = WER ihn schreiben darf (Identitaet, aufgeloest IMMER aus agent.fn_resolve_sender,
--                        nie aus LLM-Werten): owner_only | adults_only | own_user_only.
--   Die Durchsetzung liest die Registry generisch in agent.fn_check_write_permission (CASE write_permission);
--   agent.fn_set_context_facts ruft sie statt des frueheren Hardcodes (fn_sender_is_member). Der Core nennt
--   KEIN Paket hartkodiert — die Registry traegt die Bindung (Geschwister von context_validators/_renderers).
--
-- VERHALTENSNEUTRAL in P0a: alle realen Contexts werden household/owner_only geseedet -> owner_only-Zweig
--   delegiert an fn_sender_is_member = byte-identisch zum Vor-P0a-Verhalten. Die per_user-/adults_only-/
--   own_user_only-Mechanik ist gebaut + getestet, wird aber erst in P0b (career->per_user) scharfgeschaltet.
--
-- BOUNDARY (Deklaration vs. Ausfuehrung, docs/package-contract.md §3.3, analog context_validators): das PAKET
--   DEKLARIERT die Zeile NUR im manifest.json ("context_scopes"-Block { <context>: {scope, write_permission} });
--   der HOST (seed_data.sh, jq) UPSERTET sie. Paket-Rollen sind via D10 schema-isoliert und haben auf Schema
--   core KEINEN Zugriff -> koennen die Registry strukturell nicht schreiben (einziger Schreiber = Installer/
--   Owner-Superuser). KEIN own-schema-Boundary-Check im Seeder (anders als validators/renderers): die Werte
--   sind reine Daten-Enums, KEINE fn-Bezeichner — die Durchsetzung sind die CHECKs unten (Vorbild cron_labels).
--
-- EINE Zeile je Context (PRIMARY KEY): das erste Paket gewinnt; ein Zweit-Paket, das denselben Context-Namen
--   binden will, kollidiert beim Seed (ON CONFLICT sichtbar) statt still zu ueberschreiben.
--
-- Schema-Wahl "core": cross-cutting System-Infrastruktur (wie core.context_validators / core.config),
--   kein Agenten-Belang. Diese Datei enthaelt nur das SCHEMA; die Zeilen seedet seed_data.sh aus den Manifesten.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.context_scopes (
    context_name     text PRIMARY KEY,                  -- agent.core_contexts.name des facts-Contexts (z. B. 'career_profile')
    scope            text NOT NULL                      -- household = haushaltsweit (eine Zeile) | per_user = pro Person
                     CHECK (scope IN ('household', 'per_user')),
    write_permission text NOT NULL                      -- owner_only | adults_only (role∈owner,partner) | own_user_only (== Ziel-person_id)
                     CHECK (write_permission IN ('owner_only', 'adults_only', 'own_user_only')),
    package          text NOT NULL DEFAULT '',          -- deklarierendes Paket (Audit / Uninstall-Scope, fn_pkg_purge_data)
    updated_at       timestamptz NOT NULL DEFAULT now(),
    -- own_user_only setzt per_user voraus: "nur die EIGENE Zeile schreiben" ergibt nur Sinn, wenn es pro Person
    -- eine Zeile gibt. Strukturelle Invariante (DB ist Gesetz) — kein household-Context kann own_user_only sein.
    CONSTRAINT context_scopes_own_user_requires_per_user
        CHECK (write_permission <> 'own_user_only' OR scope = 'per_user')
);
-- KEIN DEFAULT auf scope/write_permission (fail-closed, "kein Default" — der Seeder liefert beide explizit, wie
-- validate_fn in context_validators). KEIN updated_at-Touch-Trigger (Muster context_validators/_renderers):
-- core.touch_updated_at lebt in core.package_registry_init.sql, das ALPHABETISCH NACH dieser Datei applied wird.
-- Der Seed setzt updated_at im ON CONFLICT DO UPDATE explizit -> kein Trigger noetig (selten beschriebene Registry).
