-- tests/db/core/test_fn_pkg_purge_data.sql
-- WS-2 (Phase 4a): core.fn_pkg_purge_data — atomarer Cross-Schema-Daten-Purge eines Pakets.
--   Loescht in FINALIZER-Reihenfolge die paket-besessenen Host-Zeilen (alle WHERE package=<pkg>):
--     protected_contexts -> core_contexts (Trigger entschaerft) -> context_validators/_renderers/advisors/
--     cron_labels/callback_handlers -> core.services + core.config + core.schema_version. NICHT: DROP SCHEMA/ROLE.
--   Atomar (RAISE->Rollback), SECURITY INVOKER (Superuser-CLI), package='core' -> {ok:false}.
-- db_test hat KEIN seed_data -> der Test seedet ein Fake-Paket 'zz' SELBST in ALLEN betroffenen Tabellen
--   (finance allein hat 0 core.services-Zeilen -> ohne eigene zz-Zeile bliebe der services-DELETE
--   ungeprueft) + eine 'core'-Zeile als Ueberlebens-Beweis. Self-contained: BEGIN ... ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_res JSONB;
BEGIN
  -- ---- Setup: Fake-Paket 'zz' in allen 5 betroffenen Tabellen ----
  -- 2x core_contexts (eine geschuetzt/registriert, eine frei) + 1 'core'-Context als Ueberlebens-Beweis.
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, package)
  VALUES ('zz_agent_instructions', 'x', 'static', 'body', 'zz'),
         ('zz_lazy_doc',           'x', 'lazy',   'body', 'zz'),
         ('zz_keep_core',          'x', 'lazy',   'body', 'core');   -- package='core' -> MUSS ueberleben
  INSERT INTO core.protected_contexts (context_name, package)
  VALUES ('zz_agent_instructions', 'zz'),
         ('zz_keep_core',          'core');                          -- core-Schutz -> MUSS ueberleben
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('zz_profile', 'zz.fn_validate_zz', 'zz');
  -- P0a: Scope-/Permission-Registry; package-besessen -> MUSS mitgepurgt werden.
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('zz_scope', 'household', 'owner_only', 'zz');
  -- WS1/WS2: Render- + Advisor-Registry (Orphan-Lecks bei finance-Uninstall, jetzt mitgepurgt).
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('zz_render', 'zz.fn_render_zz', 'zz');
  INSERT INTO core.advisors (domain, plan_context, review_fn, package)
  VALUES ('zz', 'zz_planning', 'zz.fn_advisor_review_zz', 'zz'),
         ('core_keep', 'core_planning', 'core.fn_keep_advisor', 'core');   -- core-Advisor -> MUSS ueberleben
  -- Phase 0 WS-0c: Cron-Toggle-/Label-Registry + Callback-Dispatch-Registry; package-besessen -> MUSS mitgepurgt werden.
  INSERT INTO core.cron_labels (cron_key, package)
  VALUES ('zz_cron', 'zz');
  INSERT INTO core.callback_handlers (prefix, handler_fn, package)
  VALUES ('zz', 'zz.fn_handle_zz', 'zz');
  INSERT INTO core.app_screens (screen, package, handler_fn)
  VALUES ('zz_screen', 'zz', 'zz.fn_app_screen_zz');
  -- Textkatalog: Abbild der GEBUENDELTEN Dateien, unabhaengig vom Installationsstand (Menue/Vermittler nennen auch
  -- nicht installierte Pakete beim Namen) -> MUSS die Purge UEBERLEBEN (der Seed raeumt Pakete, die das Release verlassen).
  INSERT INTO core.ui_texts (key, lang, text, package)
  VALUES ('zz.hitl.x', 'de', 'x', 'zz'), ('zz.hitl.x', 'en', 'x', 'zz');
  INSERT INTO core.services (name, workflow_id, description, package)
  VALUES ('zz:service', 'wf_zz', 'x', 'zz');   -- Nicht-Core = qualifiziert '<pkg>:<alias>' (services_name_package_check)
  INSERT INTO core.config (category, key, value, package)
  VALUES ('zz', 'k1', 'v1', 'zz');
  -- Migrations-Ledger (Phase 5, Flyway-clean): eine zz-Zeile (MUSS weg, sonst ueberspringt der
  -- Re-Install die V-Migrationen) + eine core-Zeile (MUSS ueberleben).
  INSERT INTO core.schema_version (version, filename, kind, package)
  VALUES ('Vzz001', 'Vzz001__zz.sql', 'versioned', 'zz'),
         ('Vzz_keep_core', 'x.sql',   'versioned', 'core');
  -- Advisor<->Monitor: paket-besessene Monitor-Trigger (Host-Tabelle). zz-user -> MUSS weg;
  -- core -> MUSS ueberleben; ein als package='zz' FEHL-getaggter origin='core' -> MUSS ueberleben
  -- UND darf die Purge NICHT abbrechen (M1: Protect-Trigger blockt nur, wenn der DELETE ihn trifft).
  INSERT INTO agent.monitor_triggers (domain, package, origin, label, trigger_type,
       acquisition_method, due_date, check_interval)
  VALUES ('zz',  'zz',   'user', 'zz_user_trigger',  'date', 'none', '2099-01-01', interval '7 days'),
         ('zz',  'core', 'core', 'zz_core_keep',     'date', 'none', '2099-01-01', interval '7 days'),
         ('zz',  'zz',   'core', 'zz_mistag_core',   'date', 'none', '2099-01-01', interval '7 days');

  -- ---- (1) Finalizer-Order-BEWEIS (warum protected_contexts ZUERST muss):
  --      solange die Schutz-Registry-Zeile steht, blockt der BEFORE-DELETE-Trigger. ----
  BEGIN
    DELETE FROM agent.core_contexts WHERE name = 'zz_agent_instructions';
    RAISE EXCEPTION 'FAIL purge [finalizer]: DELETE eines geschuetzten Contexts vor Registry-Entfernung akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;   -- erwartet: Protect-Trigger blockt
  END;

  -- ---- (2) Guard: package='core' -> {ok:false}, KEIN DELETE ----
  v_res := core.fn_pkg_purge_data(jsonb_build_object('package', 'core'));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL purge [core-guard]: package=core gab ok=true (%)', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = 'zz_keep_core')
     THEN RAISE EXCEPTION 'FAIL purge [core-guard]: core-Zeile faelschlich geloescht'; END IF;

  -- ---- (3) Guard: leerer/ungueltiger package -> {ok:false} ----
  v_res := core.fn_pkg_purge_data(jsonb_build_object('package', ''));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL purge [empty]: leerer package gab ok=true (%)', v_res; END IF;
  v_res := core.fn_pkg_purge_data(jsonb_build_object('package', 'ZZ-bad'));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL purge [invalid]: ungueltiger Name gab ok=true (%)', v_res; END IF;

  -- ---- (4) Purge 'zz': loescht alle 5 Mengen, Counts == geseedete Zeilen, Trigger blockt NICHT ----
  v_res := core.fn_pkg_purge_data(jsonb_build_object('package', 'zz'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL purge: ok=false (%)', v_res; END IF;
  IF (v_res->>'protected')::int  <> 1 THEN RAISE EXCEPTION 'FAIL purge: protected-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'contexts')::int   <> 2 THEN RAISE EXCEPTION 'FAIL purge: contexts-Count != 2 (%)', v_res; END IF;
  IF (v_res->>'validators')::int <> 1 THEN RAISE EXCEPTION 'FAIL purge: validators-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'scopes')::int     <> 1 THEN RAISE EXCEPTION 'FAIL purge: scopes-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'renderers')::int  <> 1 THEN RAISE EXCEPTION 'FAIL purge: renderers-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'advisors')::int   <> 1 THEN RAISE EXCEPTION 'FAIL purge: advisors-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'cron_labels')::int <> 1 THEN RAISE EXCEPTION 'FAIL purge: cron_labels-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'callback_handlers')::int <> 1 THEN RAISE EXCEPTION 'FAIL purge: callback_handlers-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'app_screens')::int <> 1 THEN RAISE EXCEPTION 'FAIL purge: app_screens-Count != 1 (%)', v_res; END IF;
  IF v_res ? 'ui_texts' THEN RAISE EXCEPTION 'FAIL purge: ui_texts gehoert nicht mehr zur Purge (%)', v_res; END IF;
  IF (v_res->>'services')::int   <> 1 THEN RAISE EXCEPTION 'FAIL purge: services-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'config')::int     <> 1 THEN RAISE EXCEPTION 'FAIL purge: config-Count != 1 (%)', v_res; END IF;
  IF (v_res->>'schema_version')::int <> 1 THEN RAISE EXCEPTION 'FAIL purge: schema_version-Count != 1 (%)', v_res; END IF;
  -- M1: nur der origin='user'-zz-Trigger wird geraeumt (1); die mistag-core-Zeile NICHT (origin-Guard).
  IF (v_res->>'monitor_triggers')::int <> 1 THEN RAISE EXCEPTION 'FAIL purge: monitor_triggers-Count != 1 (%)', v_res; END IF;

  -- nichts mit package='zz' bleibt (inkl. Ledger) — AUSSER der origin='core'-mistag (s. M1-Assert unten)
  IF EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE package='zz' AND origin='user')
     THEN RAISE EXCEPTION 'FAIL purge: zz-user-Trigger nach Purge noch da'; END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts      WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.protected_contexts  WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.context_validators  WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.context_scopes      WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.context_renderers   WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.advisors            WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.cron_labels         WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.callback_handlers   WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.app_screens         WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.services            WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.config              WHERE package='zz')
  OR EXISTS (SELECT 1 FROM core.schema_version      WHERE package='zz')
     THEN RAISE EXCEPTION 'FAIL purge: zz-Restzeilen nach Purge vorhanden'; END IF;

  -- ---- (5) Core-Zeilen ueberleben (Scope ist exakt package=<pkg>) ----
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts     WHERE name='zz_keep_core' AND package='core')
     THEN RAISE EXCEPTION 'FAIL purge: core-Context geloescht (Scope-Leck)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.protected_contexts WHERE context_name='zz_keep_core' AND package='core')
     THEN RAISE EXCEPTION 'FAIL purge: core-Schutzzeile geloescht (Scope-Leck)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.schema_version WHERE version='Vzz_keep_core' AND package='core')
     THEN RAISE EXCEPTION 'FAIL purge: core-Ledger-Zeile geloescht (Scope-Leck)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.advisors WHERE domain='core_keep' AND package='core')
     THEN RAISE EXCEPTION 'FAIL purge: core-Advisor-Zeile geloescht (Scope-Leck)'; END IF;
  IF (SELECT count(*) FROM core.ui_texts WHERE package = 'zz') <> 2
     THEN RAISE EXCEPTION 'FAIL purge: Katalog-Texte des Pakets geloescht (Menue zeigte rohe Keys)'; END IF;
  -- M1: der core-Trigger UND der als package='zz' fehl-getaggte origin='core'-Trigger ueberleben
  -- (origin-Guard) -> die Purge ist NICHT am Protect-Trigger abgebrochen.
  IF NOT EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE label='zz_core_keep' AND package='core')
     THEN RAISE EXCEPTION 'FAIL purge: core-Monitor-Trigger geloescht (Scope-Leck)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE label='zz_mistag_core' AND origin='core')
     THEN RAISE EXCEPTION 'FAIL purge [M1]: origin=core-mistag geloescht ODER Purge abgebrochen'; END IF;

  -- ---- (6) Idempotenter Doppel-Purge: 2. Lauf = alle Counts 0, kein Fehler ----
  v_res := core.fn_pkg_purge_data(jsonb_build_object('package', 'zz'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL purge [idempotent]: ok=false (%)', v_res; END IF;
  IF (v_res->>'protected')::int + (v_res->>'contexts')::int + (v_res->>'validators')::int
   + (v_res->>'scopes')::int + (v_res->>'renderers')::int + (v_res->>'advisors')::int + (v_res->>'cron_labels')::int
   + (v_res->>'callback_handlers')::int + (v_res->>'app_screens')::int + (v_res->>'monitor_triggers')::int
   + (v_res->>'services')::int + (v_res->>'config')::int + (v_res->>'schema_version')::int <> 0
     THEN RAISE EXCEPTION 'FAIL purge [idempotent]: 2. Lauf loeschte noch Zeilen (%)', v_res; END IF;

  RAISE NOTICE 'PASS core.fn_pkg_purge_data: Finalizer-Order, core-Guard, Scope-genau, Counts (inkl. Ledger), idempotent';
END $$;

ROLLBACK;
