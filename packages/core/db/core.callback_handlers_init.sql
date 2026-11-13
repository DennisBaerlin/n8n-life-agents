-- ============================================================
-- core.callback_handlers — generische Callback-Dispatch-Registry
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.callback_handlers_init.sql
--
-- Zweck: bindet ein callback_data-Prefix (der Teil vor dem ersten ":", z. B. 'job' aus 'job:up:<refnr>')
--   an eine Paket-Handler-fn(jsonb)->jsonb. Der generische Core-Dispatcher core.fn_dispatch_callback
--   schlaegt das Prefix hier nach und fuehrt die Handler-fn dynamisch aus (kein hartkodierter Paket-Name
--   im Core) — Geschwister zu core.context_validators/_renderers/advisors/cron_labels (gleiche dyn.-EXECUTE-
--   Dispatcher-Mechanik wie core.fn_advisor_review_evaluate).
--
--   Die hartkodierten Orchestrator-Switch-Arme (confirm/reject/block/unblock/cron_on/cron_off/
--   help/onboarding/learn) sind Multi-Node-Workflow-Ketten (keine Einzel-fn) und laufen nicht ueber die Registry.
--   Nur Einzel-fn-Prefixes (z. B. 'job' -> career.fn_handle_job_feedback) laufen ueber diese
--   Registry — verdrahtet an der 'extra'-Fallback-Ausgabe des 'Callback action'-Switch.
--   Ein Prefix hier darf keinen der hartkodierten Arme doppeln (sonst faengt der Switch-Arm zuerst -> tote
--   Registry-Zeile) -> contract_lint erzwingt die Kollisionsfreiheit statisch gegen den gebauten Switch.
--
-- Boundary (Deklaration vs. Ausfuehrung, docs/package-contract.md §3): das Paket deklariert die Bindung nur
--   im manifest.json ("callback_handlers"-Block { "<prefix>": "<pkg>.<fn>" }); der Host (seed_data.sh, jq)
--   upsertet die Zeile (own-schema-scoped: handler_fn muss <pkg>.* sein; der privilegierte Core core.*/agent.*).
--   Paket-Rollen sind via D10 schema-isoliert -> koennen die Registry strukturell nicht schreiben.
--   Host-Rollen-Invariante (docs/package-contract.md §8): der Dispatcher laeuft SECURITY INVOKER unter dem
--   Orchestrator-RW/Host-Credential (N8N_DB_USER), das per _emit_pkg_owner_grants EXECUTE auf <pkg>.* hat ->
--   die dynamisch ausgefuehrte Handler-fn ist erreichbar (kein DEFINER-Eskalationsfenster).
--
-- Sicherheit (dyn. SQL im Dispatcher, CVE-2018-1058): handler_fn ist nur installer-geschrieben (nie
--   $fromAI/User-Input). Der CHECK erzwingt einen schema-qualifizierten, kleingeschriebenen Bezeichner ohne
--   Injection-Zeichen; der Dispatcher pinnt search_path=pg_catalog + to_regprocedure-Guard auf die Arity.
--
-- Ein Handler je Prefix (PRIMARY KEY prefix).
--
-- Member-Permeabilitaet (Multi-Member-Callbacks): member_permeable = darf ein aufgeloestes Nicht-Owner-
--   Haushaltsmitglied diesen Callback-Prefix ueberhaupt ausloesen? Fail-closed (DEFAULT false = owner-only:
--   ein ungeseedeter/neuer Prefix oeffnet nie versehentlich). Der Dispatcher (core.fn_dispatch_callback)
--   erzwingt es (re-resolvt den Sender selbst, traut keinem Caller-Flag); die feine Autorisierung bleibt im
--   Handler (career job = Per-Item-Eigentum, estate est = Haushalts-adults_only). Boolean statt Enum: der
--   Dispatcher hat kein Per-Item-Ziel + je Prefix eine bespoke Handler-fn -> die Grob-Frage ist genuin binaer.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.callback_handlers (
    prefix           text PRIMARY KEY                       -- callback_data-Verb vor dem ersten ":" (z. B. 'job')
                     CHECK (prefix ~ '^[a-z][a-z0-9_]*$'),  -- lowercase Identifier, kein ":" / Injection-Zeichen
    handler_fn       text NOT NULL                          -- schema-qualifizierte fn(jsonb)->jsonb; bekommt das Callback-Payload, gibt {ok, toast?, message?}
                     CHECK (handler_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),  -- schema.fn, lowercase, kein Injection-Zeichen
    package          text NOT NULL DEFAULT '',              -- deklarierendes Paket (Audit / Uninstall-Purge-Scope)
    member_permeable boolean NOT NULL DEFAULT FALSE,        -- darf ein aufgeloestes Nicht-Owner-Mitglied diesen Prefix ausloesen? Fail-closed
    updated_at       timestamptz NOT NULL DEFAULT now()
);
-- Bestands-DBs: CREATE TABLE IF NOT EXISTS legt keine neue Spalte auf einer existierenden Tabelle an
-- (.claude/rules/sql.md *Schema-Aenderungs-Regeln*); das
-- -Reset-Substrat baut frisch und verdeckt das, der Seed braeche aber beim echten Upgrade.
ALTER TABLE core.callback_handlers ADD COLUMN IF NOT EXISTS member_permeable boolean NOT NULL DEFAULT FALSE;
-- Kein updated_at-Touch-Trigger (Muster core.context_validators/advisors): core.touch_updated_at lebt in
-- core.package_registry_init.sql, das alphabetisch nach dieser Datei applied wird. Der Seed setzt updated_at
-- im ON CONFLICT DO UPDATE explizit.
