-- ============================================================
-- core.monitor_acquisition_methods — Registry der Wert-Beschaffungs-Methoden des Trigger-Monitorings
--   (Phase B, docs/package-contract.md §3.9). Muster core.callback_handlers: die Core-Methoden
--   web_search | sql | none sind Host-Zeilen (acquire_fn/validate_fn NULL — direkt in den Monitor-fns
--   verdrahtet: web_search beschafft der Workflow, sql laeuft unter core_ro, none ist der reine Reminder);
--   PAKET-Methoden (z. B. finance 'fx_rate') DEKLARIERT das Paket im manifest.json-Block
--   "monitor_acquisition_methods", der HOST upsertet sie (seed_data.sh _seed_monitor_acquisition_methods,
--   own-schema-Boundary). Der Core kennt damit KEINE Paket-Methode mehr (vorher: CHECK-IN-Liste mit 'fx_rate'
--   + direkte finance.*-Reads ohne Guard -> harter Fehler / toter Heartbeat ohne finance).
--   agent.monitor_triggers.acquisition_method -> FK auf method (NO ACTION; core:V020) = DB-Gesetz.
--   PLATZHALTER: package NULL + fns NULL = eine Methode, die ein Bestands-Trigger benutzt, deren Paket aber
--   (noch) nicht registriert ist (V020 legt sie generisch an, damit der FK nie Owner-Daten loeschen muss);
--   der Paket-Seed fuellt sie, sonst bleibt ihr Trigger geparkt (fn_monitor_method_status available=false).
--   Vertraege: acquire_fn(p jsonb {spec, as_of}) -> {ok, value, unit?, as_of?, source_url?} | {ok:false, reason};
--              validate_fn(p jsonb {params}) -> {ok:true, spec, display} | {ok:false, reason}.
--   BOUNDARY: ein Paket darf nur Methoden mit fns im EIGENEN Schema registrieren (Seed-Pruefung in
--     seed_data.sh _seed_monitor_acquisition_methods; erste Registrierung gewinnt, ein fremdes Paket
--     ueberschreibt nie eine belegte Zeile).
--   SICHERHEIT: die fn-Namen landen in einem dynamischen EXECUTE (fn_monitor_acquire/_validate_params); sie
--     kommen NUR aus dieser Tabelle (Regex-CHECK schema.fn, kein Caller-Input), die Dispatcher pruefen per
--     to_regprocedure und pinnen search_path (CVE-2018-1058, Muster core.fn_dispatch_callback).
--   BUILTIN-LITERALE: web_search | sql | none stehen bewusst gespiegelt auch in fn_monitor_method_status und
--     im spec_shape-CHECK von agent.monitor_triggers (ein CHECK kann keine Tabelle lesen; die Builtins sind
--     Core-Code, keine Daten) — eine neue Core-Methode = alle drei Stellen + contract_lint Check 18.
--   KEIN updated_at-Touch-Trigger (wie callback_handlers): der Seed setzt updated_at beim Upsert explizit.
--   Tests: tests/db/core/test_monitor_acquisition_methods.sql
-- ============================================================
CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.monitor_acquisition_methods (
    method      text PRIMARY KEY CHECK (method ~ '^[a-z][a-z0-9_]*$'),
    acquire_fn  text CHECK (acquire_fn  IS NULL OR acquire_fn  ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    validate_fn text CHECK (validate_fn IS NULL OR validate_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    package     text CHECK (package IS NULL OR package ~ '^[a-z][a-z0-9_]*$'),   -- NULL = Platzhalter
    updated_at  timestamptz NOT NULL DEFAULT now(),
    -- beide fns oder keine (eine halb registrierte Methode ist weder beschaff- noch pruefbar)
    CONSTRAINT monitor_acquisition_methods_fn_pair CHECK ((acquire_fn IS NULL) = (validate_fn IS NULL)),
    -- eine Paket-Methode (package <> core) braucht ihre fns; Core-Builtins + Platzhalter nicht
    CONSTRAINT monitor_acquisition_methods_pkg_fns CHECK (package IS NULL OR package = 'core' OR acquire_fn IS NOT NULL)
);

-- Core-Builtins (selbstheilend bei jedem Apply; nie vom Paket-Seed ueberschrieben).
INSERT INTO core.monitor_acquisition_methods (method, package) VALUES
    ('web_search', 'core'), ('sql', 'core'), ('none', 'core')
ON CONFLICT (method) DO NOTHING;
