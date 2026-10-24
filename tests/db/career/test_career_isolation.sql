-- tests/db/career/test_career_isolation.sql
-- Career-Paket WS-0 (D10) — strukturelle Isolation des ZWEITEN Domaenen-Pakets + Core-Host-Lesefenster.
--
-- Beweist, dass der Paket-Vertrag GENERISCH ist (nicht finance-geformt): die engen career-Paket-Rollen
-- erreichen NUR das Schema `career`; agent.*/core.*/finance.*-Tabellen scheitern PHYSISCH
-- ("permission denied"). Core-Daten nur ueber publizierte SECURITY-DEFINER-Read-fns. Die CORE-HOST-
-- Leserolle core_ro liest dagegen auch `career` (das vom Paket geoeffnete Aufsichts-Fenster). Der RW-
-- Roundtrip (INSERT+UPDATE auf career.onboarding_state) beweist, dass die Isolation echte Writes +
-- den updated_at-Trigger NICHT bricht.
--
-- Voraussetzung: career_rw/career_ro/core_ro sind PERSISTENT provisioniert (bootstrap_test_db ruft
-- core.fn_provision_package_roles('career') NACH dem career-Schema-Apply; Prod: pkg_cmd_install Stage 3).
-- Laeuft als Superuser -> SET LOCAL ROLE braucht keine Membership; BEGIN...ROLLBACK raeumt alles weg.
-- Pattern: RAISE EXCEPTION 'FAIL ...' = Test fehlgeschlagen (ON_ERROR_STOP -> Exit 1).
BEGIN;

DO $$
DECLARE
  v_denied BOOLEAN;
  v_have   BOOLEAN;
BEGIN
  -- Die Paket-Rollen muessen existieren (sonst ist die Isolation nicht provisioniert -> harter FAIL,
  -- nicht SKIP: dieser Test IST der WS-0-Generizitaets-Nachweis fuer das 2. Paket).
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'career_ro')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'career_rw')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
    RAISE EXCEPTION 'FAIL setup: career_rw/career_ro/core_ro nicht provisioniert (bootstrap_test_db / pkg_cmd_install Stage 3 pruefen)';
  END IF;

  -- Fixture (P2b-1): career.onboarding_state.person_id ist NOT NULL + FK -> agent.persons. Eine Owner-Person
  -- seeden (via family -> Projektions-Trigger fuellt agent.persons), damit die RW-Roundtrip-INSERTs unten einen
  -- gueltigen FK-Wert haben. Als Superuser VOR den SET-LOCAL-ROLE-Bloecken.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ==========================================================
  -- A) career_ro: liest das EIGENE Schema, NICHTS anderes (VF3)
  -- ==========================================================
  -- (A1) eigenes Schema lesen DARF
  SET LOCAL ROLE career_ro;
  PERFORM 1 FROM career.onboarding_state LIMIT 1;          -- kein Fehler erwartet (leer ok)
  PERFORM 1 FROM career.job_matches LIMIT 1;               -- WS-2: neue Tabelle vom Paket-Grant erfasst
  PERFORM 1 FROM career.v_job_matches LIMIT 1;             -- WS-2: Read-View (Advisor-Read-Pfad)
  RESET ROLE;

  -- (A2) JOIN career.x agent.y -> permission denied for schema agent (die Kern-VF3-Aussage)
  SET LOCAL ROLE career_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM career.onboarding_state o LEFT JOIN agent.core_contexts c ON true LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [career_ro JOIN agent.core_contexts nicht geblockt]'; END IF;

  -- (A3) core.config direkt -> permission denied
  SET LOCAL ROLE career_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.config LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [career_ro las core.config direkt]'; END IF;

  -- (A4) Nachbar-Paket finance ist ebenso verwehrt (Paket<->Paket-Isolation, keine finance-Annahme)
  SET LOCAL ROLE career_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM finance.accounts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [career_ro las finance.accounts (Nachbar-Paket nicht isoliert)]'; END IF;

  -- (A5) publizierte Read-fn (Core-Lesefenster) -> EXECUTE erlaubt, kein Fehler
  SET LOCAL ROLE career_ro;
  PERFORM core.fn_core_api_version();
  RESET ROLE;

  -- (A6) career_ro ist read-only: INSERT ins eigene Schema scheitert (nur SELECT-GRANT + read-only-GUC)
  SET LOCAL ROLE career_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES ('__iso_ro__', 1, 'Iso', 'erika');
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [career_ro konnte schreiben]'; END IF;

  RAISE NOTICE 'PASS isolation [career_ro: eigenes Schema ja, agent/core/finance nein, Read-fn ja, read-only]';

  -- ==========================================================
  -- B) core_ro: Core-Host-Leserolle liest auch `career` (das geoeffnete Aufsichts-Fenster)
  -- ==========================================================
  -- (B1) career lesen DARF (Paket-Lesefenster, von fn_provision_package_roles unbedingt geoeffnet)
  SET LOCAL ROLE core_ro;
  PERFORM 1 FROM career.onboarding_state LIMIT 1;
  PERFORM 1 FROM career.job_matches LIMIT 1;               -- WS-2: Aufsichtsfenster deckt die neue Tabelle
  -- (B2) agent + core lesen DARF (eigene Host-Daten)
  PERFORM 1 FROM agent.core_contexts LIMIT 1;
  PERFORM 1 FROM core.config LIMIT 1;
  RESET ROLE;

  -- (B3) core.backup_key bleibt verwehrt (Backup-Key — nie an eine Leserolle; geteilte Sicherheits-
  --      Invariante, hier unabhaengig vom career-Pfad mitgeprueft = Muster test_finance_isolation B3).
  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.backup_key LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro las core.backup_key — Backup-Key-Leak]'; END IF;

  -- (B4) core_ro ist read-only: Write auf career scheitert
  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES ('__iso_coro__', 1, 'Iso', 'erika');
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro konnte career schreiben]'; END IF;

  RAISE NOTICE 'PASS isolation [core_ro: career read-only sichtbar, backup_key nein, kein Write]';

  -- ==========================================================
  -- C) career_rw: Write-Roundtrip beweist, dass die Isolation echte Writes + Trigger NICHT bricht
  -- ==========================================================
  -- search_path wie die Prod-Rolle (fn_provision_package_roles pinnt sie; SET ROLE traegt GUCs nicht).
  SET LOCAL search_path = pg_catalog, career, agent, core;
  SET LOCAL ROLE career_rw;

  -- INSERT + UPDATE auf career.onboarding_state (der updated_at-Touch-Trigger feuert beim UPDATE; person_id=erika
  -- erfuellt NOT NULL + FK -> agent.persons, P2b-1; FK-RI-Check laeuft privilegiert, career_rw braucht kein agent-SELECT).
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES ('__iso_rw__', 1, 'Iso RW', 'erika');
  UPDATE career.onboarding_state SET status = 'completed' WHERE section_key = '__iso_rw__' AND person_id = 'erika';
  SELECT EXISTS (
    SELECT 1 FROM career.onboarding_state WHERE section_key = '__iso_rw__' AND person_id = 'erika' AND status = 'completed'
  ) INTO v_have;
  IF NOT v_have THEN RAISE EXCEPTION 'FAIL rw [career.onboarding_state Write-Roundtrip]'; END IF;

  -- career_rw bleibt isoliert: agent.* unerreichbar (VF3 auch fuer die Schreibrolle)
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM agent.core_contexts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [career_rw erreichte agent.core_contexts]'; END IF;

  RAISE NOTICE 'PASS isolation [career_rw: Write-Roundtrip (INSERT+UPDATE+Trigger), agent.* verwehrt]';

  RAISE NOTICE 'PASS career isolation (VF3 generisch fuer das 2. Paket + core_ro-Lesefenster + career_rw-Roundtrip)';
END $$;

ROLLBACK;
