-- tests/db/paperless/test_paperless_isolation.sql
-- Paperless-Paket (D10) — strukturelle Isolation des Domaenen-Pakets + Core-Host-Lesefenster.
--
-- Muster 1:1 tests/db/estate/test_estate_isolation.sql: die engen paperless-Paket-Rollen erreichen NUR
-- das Schema `paperless`; agent.*/core.*/finance.*-Tabellen scheitern PHYSISCH. Seit v0.3.0 (reiner Lese-Zugang
-- auf Paperless-NGX, keine eigenen Tabellen) ist die EINE reale Kopplung der Config-Read: die Paket-Tools lesen
-- die Instanz-Adresse unter paperless_ro ueber das publizierte Core-Fenster core.fn_config_get (B) — der
-- direkte core.config-Zugriff bleibt gesperrt (A).
--
-- Voraussetzung: paperless_rw/paperless_ro/core_ro sind PERSISTENT provisioniert (bootstrap_test_db ruft
-- core.fn_provision_package_roles('paperless') NACH dem paperless-Schema-Apply; Prod: pkg_cmd_install Stage 3).
BEGIN;

DO $$
DECLARE
  v_denied boolean;
  v_url    text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'paperless_ro')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'paperless_rw')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
    RAISE EXCEPTION 'FAIL setup: paperless_rw/paperless_ro/core_ro nicht provisioniert (bootstrap_test_db / pkg_cmd_install Stage 3 pruefen)';
  END IF;

  -- Fixture (als Superuser): die Instanz-Adresse, die die Paket-Tools lesen
  INSERT INTO core.config (category, key, value, package)
  VALUES ('general', 'paperless_url', 'http://paperless.iso.test:8000', 'paperless')
  ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value, package = EXCLUDED.package;
  -- Fixture: eine Tabelle im Paket-Schema (das Paket selbst hat keine) fuer die Schreib-/Lese-Fence-Proben
  CREATE TABLE paperless.zz_iso_probe (id int PRIMARY KEY);
  PERFORM core.fn_provision_package_roles(jsonb_build_object('package', 'paperless'));   -- Grants auf die neue Tabelle

  -- ==========================================================
  -- A) paperless_ro: kommt an NICHTS ausserhalb des eigenen Schemas (VF3)
  -- ==========================================================
  SET LOCAL ROLE paperless_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM agent.core_contexts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [paperless_ro las agent.core_contexts]'; END IF;

  SET LOCAL ROLE paperless_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.config LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [paperless_ro las core.config direkt]'; END IF;

  SET LOCAL ROLE paperless_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM finance.accounts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [paperless_ro las finance.accounts]'; END IF;

  -- Publizierte Core-Read-fn erreichbar
  SET LOCAL ROLE paperless_ro;
  PERFORM core.fn_core_api_version();
  RESET ROLE;

  -- (A6, estate-Paritaet) paperless_ro ist read-only: direkter INSERT ins eigene Schema scheitert
  SET LOCAL ROLE paperless_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO paperless.zz_iso_probe (id) VALUES (1);
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [paperless_ro konnte direkt schreiben]'; END IF;

  -- ==========================================================
  -- B) PERSPEKTIV-TEST: paperless_ro liest die Instanz-Adresse ueber das Core-Config-Fenster
  --    (genau der Load-config-Pfad der Paket-Tools; der Superuser-Lauf allein saehe einen Grant-Bruch nie)
  -- ==========================================================
  SET LOCAL ROLE paperless_ro;
  v_url := core.fn_config_get('paperless', 'general', 'paperless_url');
  RESET ROLE;
  IF v_url IS DISTINCT FROM 'http://paperless.iso.test:8000' THEN
    RAISE EXCEPTION 'FAIL perspektive [paperless_ro las paperless_url nicht ueber fn_config_get: %]', v_url;
  END IF;

  -- ==========================================================
  -- C) paperless_rw: schreibt im eigenen Schema, agent.* bleibt zu
  -- ==========================================================
  SET LOCAL ROLE paperless_rw;
  INSERT INTO paperless.zz_iso_probe (id) VALUES (2);
  RESET ROLE;

  SET LOCAL ROLE paperless_rw;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM agent.core_contexts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [paperless_rw las agent.core_contexts]'; END IF;

  -- ==========================================================
  -- D) core_ro (Host-Aufsichtsfenster): liest paperless (read_surface-Invariante),
  --    bleibt aber vom Backup-Schluessel ausgesperrt UND read-only (estate-Paritaet B3/B4)
  -- ==========================================================
  SET LOCAL ROLE core_ro;
  PERFORM 1 FROM paperless.zz_iso_probe LIMIT 1;
  RESET ROLE;

  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.backup_key LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro las core.backup_key]'; END IF;

  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO paperless.zz_iso_probe (id) VALUES (3);
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro konnte ins Paket-Schema schreiben]'; END IF;

  RAISE NOTICE 'PASS isolation [paperless_ro/rw isoliert; URL-Config ueber fn_config_get; core_ro-Fenster/-Fence/-read-only]';
END $$;

ROLLBACK;
