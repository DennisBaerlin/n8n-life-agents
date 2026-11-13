-- ============================================================
-- core.context_renderers — generische Render-Registry
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.context_renderers_init.sql
--
-- Zweck: bindet einen facts-tragenden Context-Namen (z. B. 'financial_planning', 'family',
--   'finance_profile') an die Paket-/Core-Render-fn, die seinen autoritativen Fakten-Header
--   baut (Ableitungen via SQL — Glidepath-Jahr, Rentenjahr, Alter — nie gespeichert). Die
--   generische Engine core.fn_fetch_context dispatcht generisch ueber diese Tabelle
--   (NEW p_name -> render_fn -> dyn. EXECUTE) und wrappt Banner + Header + _meta-Stempel +
--   Prosa-Body — der Core nennt kein Paket/keinen Context hartkodiert.
--
-- Symmetrie zu core.context_validators: dasselbe Deklaration-vs-Ausfuehrung-Muster.
--   Boundary (docs/package-contract.md §3.3): das Paket deklariert die Bindung nur im manifest.json
--   ("context_renderers"-Block); der Host (seed_data.sh, jq) upsertet die Zeile. Paket-Rollen sind
--   via D10 schema-isoliert und haben auf Schema core keinen Zugriff -> koennen die Registry
--   strukturell nicht schreiben (einziger Schreiber = Installer/Owner-Superuser). seed_data prueft
--   zusaetzlich own-schema-scoping (ein Paket bindet nur <pkg>.* bzw. der Core core.*/agent.*).
--
-- Ein Renderer je Context (PRIMARY KEY): erstes Paket gewinnt; ein Zweit-Paket, das denselben
--   Context-Namen binden will, kollidiert beim Seed (ON CONFLICT sichtbar) statt still zu ueberschreiben.
--
-- Sicherheit (dyn. SQL in der Engine, CVE-2018-1058): render_fn ist nur installer-geschrieben (nie
--   $fromAI/User-Input; kein zeilen-setzbares metadata.render_fn-Flag, das ein Angreifer mit
--   Context-Write setzen koennte). Der CHECK erzwingt einen schema-
--   qualifizierten, kleingeschriebenen Bezeichner ohne Injection-Zeichen; die Engine pinnt
--   search_path=pg_catalog + ruft den voll qualifizierten Namen + to_regprocedure(...(text))-Guard.
--   Renderer-Signatur ist uniform fn(text)->text (Context-Name als Argument) — anders als die
--   Validatoren fn(jsonb)->text.
--
-- Schema-Wahl "core": cross-cutting System-Infrastruktur (wie core.context_validators / core.config),
--   kein Agenten-Belang. Diese Datei enthaelt nur das Schema; die Zeilen seedet seed_data.sh aus den
--   Manifesten (Paket-Contexts) bzw. dem Core-Manifest (family/finance_profile).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.context_renderers (
    context_name text PRIMARY KEY,                 -- agent.core_contexts.name der facts-Zeile (z. B. 'financial_planning')
    render_fn    text NOT NULL                     -- schema-qualifizierte fn(text)->text; baut den autoritativen Header (NULL = nur Prosa)
                 CHECK (render_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),  -- schema.fn, lowercase, fuehrender Buchstabe, kein Injection-Zeichen
    package      text NOT NULL DEFAULT '',          -- deklarierendes Paket (Audit / Uninstall-Scope)
    updated_at   timestamptz NOT NULL DEFAULT now()
);
-- Kein updated_at-Touch-Trigger (Muster core.context_validators): core.touch_updated_at lebt in
-- core.package_registry_init.sql, das alphabetisch nach dieser Datei applied wird. Der Seed setzt
-- updated_at im ON CONFLICT DO UPDATE explizit -> kein Trigger noetig (selten beschriebene Registry).
