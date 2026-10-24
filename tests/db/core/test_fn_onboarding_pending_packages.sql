-- tests/db/core/test_fn_onboarding_pending_packages.sql
-- WS-3 (Onboarding-UX): core.fn_onboarding_pending_packages() — generische Entdeckung der AKTIVEN Pakete
--   (status='active', package<>'core'), deren <pkg>.onboarding_state-Tabelle existiert UND >=1 offene
--   Sektion (status='unknown') hat. Rueckgabe {ok:true, pending:[{package, open:[{key,label}]}]}.
--   'completed'/'skipped' zaehlen als bewusst aufgeloest (wie fn_onboarding_status: complete = kein unknown).
-- db_test hat KEIN seed_data -> finance-Sektionen + package_registry-Zeilen self-seeden. BEGIN..ROLLBACK.
-- Rollen-Perspektive (core_ro EXECUTE / finance_ro denied) -> tests/db/cross/test_role_permissions.sql (3d).
BEGIN;

DO $$
DECLARE
  r     JSONB;
  v_fin JSONB;
BEGIN
  -- ---------- Setup: finance-Sektionen self-seeden + finance/core ins Registry ----------
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES
    ('accounts',1,'Konten'),('investments',2,'Depot'),('liabilities',3,'Kredite'),
    ('protection',4,'Versicherungen'),('goals',5,'Ziele')
  ON CONFLICT (section_key) DO NOTHING;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status='active';
  INSERT INTO core.package_registry (package, version, status) VALUES ('core','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status='active';

  -- ---------- (i) finance active + >=1 Sektion unknown -> finance in pending mit open[] ----------
  UPDATE finance.onboarding_state SET status='unknown', skipped_at=NULL;
  r := core.fn_onboarding_pending_packages();
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [(i) ok<>true]: %', r; END IF;
  SELECT e INTO v_fin FROM jsonb_array_elements(r->'pending') e WHERE e->>'package'='finance';
  IF v_fin IS NULL THEN RAISE EXCEPTION 'FAIL [(i) finance fehlt in pending]: %', r; END IF;
  IF jsonb_array_length(v_fin->'open') <> 5 THEN RAISE EXCEPTION 'FAIL [(i) open<>5]: %', v_fin; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_fin->'open') o WHERE (o ? 'key') AND (o ? 'label')) THEN
    RAISE EXCEPTION 'FAIL [(i) open-Eintrag ohne key/label]: %', v_fin; END IF;

  -- ---------- (iii) 'core' nie in pending (per WHERE package<>'core') ----------
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'pending') e WHERE e->>'package'='core') THEN
    RAISE EXCEPTION 'FAIL [(iii) core in pending]: %', r; END IF;

  -- ---------- (ii) alle completed/skipped -> finance NICHT in pending ----------
  UPDATE finance.onboarding_state SET status='completed', skipped_at=NULL;
  UPDATE finance.onboarding_state SET status='skipped', skipped_at=now() WHERE section_key='goals';
  r := core.fn_onboarding_pending_packages();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'pending') e WHERE e->>'package'='finance') THEN
    RAISE EXCEPTION 'FAIL [(ii) finance trotz completed/skipped in pending]: %', r; END IF;
  -- ---------- (vi) keine offenen Pakete -> {ok:true, pending:[]} ----------
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [(vi) ok<>true bei leer]: %', r; END IF;
  IF jsonb_array_length(r->'pending') <> 0 THEN RAISE EXCEPTION 'FAIL [(vi) pending nicht leer]: %', r; END IF;

  -- ---------- (v) status<>'active' -> nicht iteriert (eine finance-Sektion wieder offen, finance 'installed') ----------
  UPDATE finance.onboarding_state SET status='unknown' WHERE section_key='accounts';
  UPDATE core.package_registry SET status='installed' WHERE package='finance';
  r := core.fn_onboarding_pending_packages();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'pending') e WHERE e->>'package'='finance') THEN
    RAISE EXCEPTION 'FAIL [(v) nicht-aktives Paket in pending]: %', r; END IF;
  UPDATE core.package_registry SET status='active' WHERE package='finance';

  -- ---------- (iv) aktives Paket OHNE onboarding_state-Tabelle -> uebersprungen (kein Fehler) ----------
  INSERT INTO core.package_registry (package, version, status) VALUES ('testpkg','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status='active';
  r := core.fn_onboarding_pending_packages();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'pending') e WHERE e->>'package'='testpkg') THEN
    RAISE EXCEPTION 'FAIL [(iv) testpkg ohne onboarding_state in pending]: %', r; END IF;
  -- finance hat jetzt 'accounts' wieder unknown -> muss erscheinen (beweist: (iv)-Skip bricht nicht die Schleife)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'pending') e WHERE e->>'package'='finance') THEN
    RAISE EXCEPTION 'FAIL [(iv) finance fehlt trotz offener accounts-Sektion]: %', r; END IF;

  RAISE NOTICE 'PASS core.fn_onboarding_pending_packages [active+open / completed+skipped / core / inactive / kein-table]';
END $$;

ROLLBACK;
