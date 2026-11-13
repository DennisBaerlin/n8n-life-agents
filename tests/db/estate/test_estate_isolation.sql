-- tests/db/estate/test_estate_isolation.sql
-- Strukturelle Isolation des Pakets estate + Core-Host-Lesefenster.
--
-- Muster wie tests/db/career/test_career_isolation.sql: die engen
-- estate-Paket-Rollen erreichen nur das Schema `estate`; agent.*/core.*/finance.*-Tabellen scheitern
-- physisch ("permission denied"). Core-Daten nur ueber publizierte SECURITY-DEFINER-Read-fns. Die
-- Core-Host-Leserolle core_ro liest dagegen auch `estate` (das vom Paket geoeffnete Aufsichts-Fenster,
-- core.fn_provision_package_roles grantet core_ro SELECT). Der RW-Roundtrip (INSERT+UPDATE auf estate.onboarding_state,
-- household-Form ohne person_id) beweist, dass die Isolation echte Writes + den updated_at-Trigger
-- nicht bricht.
--
-- Voraussetzung: estate_rw/estate_ro/core_ro sind persistent provisioniert (bootstrap_test_db ruft
-- core.fn_provision_package_roles('estate') nach dem estate-Schema-Apply; Prod: pkg_cmd_install Stage 3).
-- Laeuft als Superuser -> SET LOCAL ROLE braucht keine Membership; BEGIN...ROLLBACK raeumt alles weg.
-- Pattern: RAISE EXCEPTION 'FAIL ...' = Test fehlgeschlagen (ON_ERROR_STOP -> Exit 1).
BEGIN;

DO $$
DECLARE
  v_denied BOOLEAN;
  v_have   BOOLEAN;
BEGIN
  -- Die Paket-Rollen muessen existieren (sonst ist die Isolation nicht provisioniert -> harter FAIL,
  -- nicht SKIP: dieser Test ist der Generizitaets-Nachweis des Paket-Vertrags).
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'estate_ro')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'estate_rw')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
    RAISE EXCEPTION 'FAIL setup: estate_rw/estate_ro/core_ro nicht provisioniert (bootstrap_test_db / pkg_cmd_install Stage 3 pruefen)';
  END IF;

  -- ==========================================================
  -- A) estate_ro: liest das eigene Schema, nichts anderes
  -- ==========================================================
  -- (A1) eigenes Schema lesen darf (leer ok); directive_types muss den Seed tragen.
  SET LOCAL ROLE estate_ro;
  PERFORM 1 FROM estate.onboarding_state LIMIT 1;
  PERFORM 1 FROM estate.directives LIMIT 1;
  PERFORM 1 FROM estate.directive_types LIMIT 1;
  RESET ROLE;

  -- (A2) JOIN estate.x agent.y -> permission denied for schema agent (die Kern-Aussage)
  SET LOCAL ROLE estate_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM estate.directives d LEFT JOIN agent.core_contexts c ON true LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [estate_ro JOIN agent.core_contexts nicht geblockt]'; END IF;

  -- (A3) core.config direkt -> permission denied
  SET LOCAL ROLE estate_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.config LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [estate_ro las core.config direkt]'; END IF;

  -- (A4) Nachbar-Paket finance ist ebenso verwehrt (Paket<->Paket-Isolation; estate liest finance
  --      nur ueber publizierte provides.reads-fns, nie Tabellen direkt)
  SET LOCAL ROLE estate_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM finance.accounts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [estate_ro las finance.accounts (Nachbar-Paket nicht isoliert)]'; END IF;

  -- (A5) publizierte Read-fn (Core-Lesefenster, consumes.reads) -> EXECUTE erlaubt, kein Fehler
  SET LOCAL ROLE estate_ro;
  PERFORM core.fn_core_api_version();
  RESET ROLE;

  -- (A6) estate_ro ist read-only: INSERT ins eigene Schema scheitert (nur SELECT-GRANT + read-only-GUC)
  SET LOCAL ROLE estate_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO estate.onboarding_state (section_key, ord, label) VALUES ('__iso_ro__', 1, 'Iso');
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [estate_ro konnte schreiben]'; END IF;

  RAISE NOTICE 'PASS isolation [estate_ro: eigenes Schema ja, agent/core/finance nein, Read-fn ja, read-only]';

  -- ==========================================================
  -- B) core_ro: Core-Host-Leserolle liest auch `estate` (das geoeffnete Aufsichts-Fenster)
  -- ==========================================================
  -- (B1) estate lesen darf (Paket-Lesefenster, von fn_provision_package_roles unbedingt geoeffnet)
  SET LOCAL ROLE core_ro;
  PERFORM 1 FROM estate.onboarding_state LIMIT 1;
  PERFORM 1 FROM estate.directives LIMIT 1;
  -- (B2) agent + core lesen darf (eigene Host-Daten)
  PERFORM 1 FROM agent.core_contexts LIMIT 1;
  PERFORM 1 FROM core.config LIMIT 1;
  RESET ROLE;

  -- (B3) core.backup_key bleibt verwehrt (Backup-Key — nie an eine Leserolle; geteilte Sicherheits-
  --      Invariante, hier unabhaengig vom estate-Pfad mitgeprueft = Muster test_career_isolation B3).
  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.backup_key LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro las core.backup_key — Backup-Key-Leak]'; END IF;

  -- (B4) core_ro ist read-only: Write auf estate scheitert
  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO estate.onboarding_state (section_key, ord, label) VALUES ('__iso_coro__', 1, 'Iso');
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro konnte estate schreiben]'; END IF;

  RAISE NOTICE 'PASS isolation [core_ro: estate read-only sichtbar, backup_key nein, kein Write]';

  -- ==========================================================
  -- C) estate_rw: Write-Roundtrip beweist, dass die Isolation echte Writes + Trigger nicht bricht
  -- ==========================================================
  -- search_path wie die Prod-Rolle (fn_provision_package_roles pinnt sie; SET ROLE traegt GUCs nicht).
  SET LOCAL search_path = pg_catalog, estate, agent, core;
  SET LOCAL ROLE estate_rw;

  -- INSERT + UPDATE auf estate.onboarding_state (household-Form ohne person_id — anders als career;
  -- der updated_at-Touch-Trigger feuert beim UPDATE).
  INSERT INTO estate.onboarding_state (section_key, ord, label) VALUES ('__iso_rw__', 1, 'Iso RW');
  UPDATE estate.onboarding_state SET status = 'completed' WHERE section_key = '__iso_rw__';
  SELECT EXISTS (
    SELECT 1 FROM estate.onboarding_state WHERE section_key = '__iso_rw__' AND status = 'completed'
  ) INTO v_have;
  IF NOT v_have THEN RAISE EXCEPTION 'FAIL rw [estate.onboarding_state Write-Roundtrip]'; END IF;

  -- estate_rw bleibt isoliert: agent.* unerreichbar (auch fuer die Schreibrolle)
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM agent.core_contexts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [estate_rw erreichte agent.core_contexts]'; END IF;

  RAISE NOTICE 'PASS isolation [estate_rw: Write-Roundtrip (INSERT+UPDATE+Trigger), agent.* verwehrt]';

  RAISE NOTICE 'PASS estate isolation (VF3 generisch fuer das 3. Paket + core_ro-Lesefenster + estate_rw-Roundtrip)';
END $$;

ROLLBACK;
