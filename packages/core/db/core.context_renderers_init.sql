-- ============================================================
-- core.context_renderers — generische Render-Registry (WS1a, Core-Advisor-Engine)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.context_renderers_init.sql
--
-- Zweck: bindet einen facts-tragenden Context-Namen (z. B. 'financial_planning', 'family',
--   'finance_profile') an die PAKET-/Core-Render-fn, die seinen autoritativen Fakten-HEADER
--   baut (Ableitungen via SQL — Glidepath-Jahr, Rentenjahr, Alter — NIE gespeichert). Die
--   generische Engine core.fn_fetch_context dispatcht GENERISCH ueber diese Tabelle
--   (NEW p_name -> render_fn -> dyn. EXECUTE) und wrappt Banner + Header + _meta-Stempel +
--   Prosa-Body — der Core nennt KEIN Paket/keinen Context hartkodiert (ersetzt den fruehen
--   name-gebundenen Whitelist-CASE in fn_fetch_context, der pro Context die render_fn hartkodierte).
--
-- SYMMETRIE zu core.context_validators (WS-B1/D12): dasselbe Deklaration-vs-Ausfuehrung-Muster.
--   BOUNDARY (docs/package-contract.md §3.3): das PAKET DEKLARIERT die Bindung NUR im manifest.json
--   ("context_renderers"-Block); der HOST (seed_data.sh, jq) UPSERTET die Zeile. Paket-Rollen sind
--   via D10 schema-isoliert und haben auf Schema core KEINEN Zugriff -> koennen die Registry
--   strukturell nicht schreiben (einziger Schreiber = Installer/Owner-Superuser). seed_data prueft
--   zusaetzlich own-schema-scoping (ein Paket bindet nur <pkg>.* bzw. der Core core.*/agent.*).
--
-- EIN Renderer je Context (PRIMARY KEY): erstes Paket gewinnt; ein Zweit-Paket, das denselben
--   Context-Namen binden will, kollidiert beim Seed (ON CONFLICT sichtbar) statt still zu ueberschreiben.
--
-- SICHERHEIT (dyn. SQL in der Engine, CVE-2018-1058): render_fn ist NUR installer-geschrieben (nie
--   $fromAI/User-Input — das ersetzt das frueher mutable, zeilen-setzbare metadata.render_fn-Flag,
--   das ein Angreifer mit Context-Write haette setzen koennen). Der CHECK erzwingt einen schema-
--   qualifizierten, kleingeschriebenen Bezeichner ohne Injection-Zeichen; die Engine pinnt
--   search_path=pg_catalog + ruft den voll qualifizierten Namen + to_regprocedure(...(text))-Guard.
--   Renderer-Signatur ist UNIFORM fn(text)->text (Context-Name als Argument) — anders als die
--   Validatoren fn(jsonb)->text.
--
-- Schema-Wahl "core": cross-cutting System-Infrastruktur (wie core.context_validators / core.config),
--   kein Agenten-Belang. Diese Datei enthaelt nur das SCHEMA; die Zeilen seedet seed_data.sh aus den
--   Manifesten (Paket-Contexts) bzw. dem Core-Manifest (family/finance_profile in WS1b).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.context_renderers (
    context_name text PRIMARY KEY,                 -- agent.core_contexts.name der facts-Zeile (z. B. 'financial_planning')
    render_fn    text NOT NULL                     -- schema-qualifizierte fn(text)->text; baut den autoritativen Header (NULL = nur Prosa)
                 CHECK (render_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),  -- schema.fn, lowercase, fuehrender Buchstabe, kein Injection-Zeichen
    package      text NOT NULL DEFAULT '',          -- deklarierendes Paket (Audit / Uninstall-Scope)
    updated_at   timestamptz NOT NULL DEFAULT now()
);
-- KEIN updated_at-Touch-Trigger (Muster core.context_validators): core.touch_updated_at lebt in
-- core.package_registry_init.sql, das ALPHABETISCH NACH dieser Datei applied wird. Der Seed setzt
-- updated_at im ON CONFLICT DO UPDATE explizit -> kein Trigger noetig (selten beschriebene Registry).
