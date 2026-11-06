-- tests/db/finance/test_finance_isolation.sql
-- Phase 3a (D10) — strukturelle Isolation des Finance-PAKETS + Core-Host-Lesefenster + RW-Roundtrip.
--
-- VF3 (die Kernaussage der Paket-Architektur): die ENGEN Finance-Paket-Rollen erreichen NUR das
-- Schema `finance`; agent.*/core.*-Tabellen scheitern PHYSISCH ("permission denied"). Core-Daten
-- nur ueber publizierte SECURITY-DEFINER-Read-fns. Die CORE-HOST-Leserolle core_ro liest dagegen
-- breit (agent+core+finance, read-only) — das vom Finance-Paket geoeffnete Lesefenster. Der RW-
-- Roundtrip beweist, dass die Isolation echte Writes NICHT bricht (Trigger/Sequenzen/ON CONFLICT).
--
-- Voraussetzung: finance_rw/finance_ro/core_ro sind PERSISTENT provisioniert (bootstrap_test_db
-- ruft core.fn_provision_package_roles('finance') + util_create_core_ro; Prod: apply_schema Phase 4).
-- Laeuft als Superuser → SET LOCAL ROLE braucht keine Membership; BEGIN…ROLLBACK raeumt alles weg.
-- Pattern: RAISE EXCEPTION 'FAIL …' = Test fehlgeschlagen (ON_ERROR_STOP -> Exit 1).
BEGIN;

DO $$
DECLARE
  v_denied  BOOLEAN;
  v_res     JSONB;
  v_acct    INT;
  v_balance NUMERIC;
  v_have    BOOLEAN;
BEGIN
  -- Die Paket-Rollen muessen existieren (sonst ist die Isolation nicht provisioniert -> harter FAIL,
  -- nicht SKIP: dieser Test IST der 3a-Isolations-Nachweis).
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_ro')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_rw')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
    RAISE EXCEPTION 'FAIL setup: finance_rw/finance_ro/core_ro nicht provisioniert (bootstrap_test_db / apply_schema Phase 4 pruefen)';
  END IF;

  -- ==========================================================
  -- A) finance_ro: liest das EIGENE Schema, NICHTS anderes (VF3)
  -- ==========================================================
  -- (A1) eigenes Schema lesen DARF
  SET LOCAL ROLE finance_ro;
  PERFORM 1 FROM finance.accounts LIMIT 1;          -- kein Fehler erwartet (leer ok)
  RESET ROLE;

  -- (A2) JOIN finance.x agent.y -> permission denied for schema agent (die Kern-VF3-Aussage)
  SET LOCAL ROLE finance_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM finance.accounts a LEFT JOIN agent.core_contexts c ON true LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [finance_ro JOIN agent.core_contexts nicht geblockt]'; END IF;

  -- (A3) core.config direkt -> permission denied
  SET LOCAL ROLE finance_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.config LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [finance_ro las core.config direkt]'; END IF;

  -- (A4) publizierte Read-fn (Core-Lesefenster) -> EXECUTE erlaubt, kein Fehler
  SET LOCAL ROLE finance_ro;
  PERFORM 1 FROM core.fn_advisor_read_plan('finance');
  RESET ROLE;

  -- (A5) finance_ro ist read-only: INSERT ins eigene Schema scheitert (nur SELECT-GRANT)
  SET LOCAL ROLE finance_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO finance.currencies (code, minor_unit) VALUES ('XTS', 2);
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [finance_ro konnte schreiben]'; END IF;

  RAISE NOTICE 'PASS isolation [finance_ro: eigenes Schema ja, agent/core nein, Read-fn ja, read-only]';

  -- ==========================================================
  -- B) core_ro: Core-Host-Leserolle liest BREIT read-only (das geoeffnete Fenster)
  -- ==========================================================
  -- (B1) finance lesen DARF (Paket-Lesefenster, von fn_provision_package_roles geoeffnet)
  SET LOCAL ROLE core_ro;
  PERFORM 1 FROM finance.accounts LIMIT 1;
  -- (B2) agent + core lesen DARF (eigene Host-Daten)
  PERFORM 1 FROM agent.core_contexts LIMIT 1;
  PERFORM 1 FROM core.config LIMIT 1;
  RESET ROLE;

  -- (B3) core.backup_key bleibt verwehrt (Backup-Key — nie an eine Leserolle)
  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.backup_key LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro las core.backup_key — Backup-Key-Leak]'; END IF;

  -- (B4) core_ro ist read-only: Write auf finance scheitert
  SET LOCAL ROLE core_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO finance.currencies (code, minor_unit) VALUES ('XTS', 2);
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [core_ro konnte finance schreiben]'; END IF;

  RAISE NOTICE 'PASS isolation [core_ro: agent+core+finance read-only, core.backup_key nein]';

  -- ==========================================================
  -- C) finance_rw: Write-Roundtrip beweist, dass die Isolation echte Writes NICHT bricht
  -- ==========================================================
  -- search_path wie die Prod-Rolle (fn_provision_package_roles pinnt sie; SET ROLE traegt GUCs nicht).
  SET LOCAL search_path = pg_catalog, finance, agent, core;
  SET LOCAL ROLE finance_rw;

  -- create_account + book_transaction unter finance_rw (Trigger balance-init + balance-update,
  -- Sequenzen, fn_ensure_currency ON CONFLICT laufen alle in finance unter dieser Rolle).
  v_res := finance.fn_create_account(
    '{"name":"__iso_rw_acct__","account_type":"cash","account_holder":"Iso","currency":"EUR"}'::jsonb);
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL rw [create_account]: %', v_res; END IF;
  v_acct := (v_res->>'account_id')::int;

  v_res := finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct, 'amount', '250', 'direction', 'inflow',
    'category', 'other', 'transaction_date', CURRENT_DATE::text));
  IF NOT (v_res ? 'tx_id') THEN RAISE EXCEPTION 'FAIL rw [book_transaction]: %', v_res; END IF;

  v_balance := finance.fn_get_balance(v_acct);
  IF v_balance IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'FAIL rw [Trigger-Balance]: erwartet 250, got %', v_balance;
  END IF;

  -- finance_rw bleibt isoliert: agent.* unerreichbar (VF3 auch fuer die Schreibrolle)
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM agent.core_contexts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3 [finance_rw erreichte agent.core_contexts]'; END IF;

  RAISE NOTICE 'PASS isolation [finance_rw: Write-Roundtrip (balance=250 via Trigger), agent.* verwehrt]';

  RAISE NOTICE 'PASS finance isolation (VF3 + core_ro-Lesefenster + finance_rw-Roundtrip)';
END $$;

ROLLBACK;
