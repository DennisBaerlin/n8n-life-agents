-- tests/db/core/test_fn_onboarding_status.sql
-- WS-B3 DRY-Onboarding: core.fn_onboarding_status(p_package) ist die kombinierte, paket-uebergreifende
-- Lese-Schnittstelle (core-Bein immer + optionales Paket-Bein); core.fn_set_onboarding_section(p) setzt
-- EINE Sektion (paket-schluessel-parametrisiert, status text+CHECK, kein ENUM-Cast).
--   complete = core.complete AND (package.complete falls p_package gesetzt). 'skipped' zaehlt als aufgeloest.
-- db_test hat KEIN seed_data -> die finance.onboarding_state-Zeilen self-seeden (guide_init seedet household).
-- In BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE r JSONB;
BEGIN
  -- ---------- Setup: finance-Sektionen self-seeden (db_test = kein seed_data); Baseline 'unknown' ----------
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES
    ('accounts',1,'Konten'),('investments',2,'Depot'),('liabilities',3,'Kredite'),
    ('protection',4,'Versicherungen'),('goals',5,'Ziele')
  ON CONFLICT (section_key) DO NOTHING;
  UPDATE agent.guide_onboarding_state SET status='unknown', skipped_at=NULL;
  UPDATE finance.onboarding_state    SET status='unknown', skipped_at=NULL;

  -- ---------- 1) core-Default (kein Paket): nur core, household unknown -> complete=false, package=null ----------
  r := core.fn_onboarding_status();
  IF (r->>'complete')::boolean THEN RAISE EXCEPTION 'FAIL [core-default complete trotz household unknown]: %', r; END IF;
  IF jsonb_typeof(r->'core') <> 'object' THEN RAISE EXCEPTION 'FAIL [core-Bein fehlt]: %', r; END IF;
  IF (r->'package') IS NOT NULL AND r->'package' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [package muss null sein ohne p_package]: %', r->'package'; END IF;

  -- ---------- 2) kombiniert 'finance': beide unknown -> complete=false; open = Union (>= 2) ----------
  r := core.fn_onboarding_status('finance');
  IF (r->>'complete')::boolean THEN RAISE EXCEPTION 'FAIL [finance kombiniert complete trotz unknown]: %', r; END IF;
  IF jsonb_array_length(r->'open') < 2 THEN RAISE EXCEPTION 'FAIL [open-Union zu klein]: %', r->'open'; END IF;
  IF (r->'package'->>'name') <> 'finance' THEN RAISE EXCEPTION 'FAIL [package.name <> finance]: %', r->'package'; END IF;

  -- ---------- 3) alles completed -> kombiniert complete=true, open leer ----------
  r := core.fn_set_onboarding_section('{"package":"core","section_key":"household","status":"completed"}');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [set core household: %]', r; END IF;
  PERFORM core.fn_set_onboarding_section(jsonb_build_object('package','finance','section_key',s.k,'status','completed'))
    FROM (VALUES ('accounts'),('investments'),('liabilities'),('protection'),('goals')) AS s(k);
  r := core.fn_onboarding_status('finance');
  IF NOT (r->>'complete')::boolean THEN RAISE EXCEPTION 'FAIL [kombiniert complete=false trotz aller completed]: %', r; END IF;
  IF jsonb_array_length(r->'open') <> 0 THEN RAISE EXCEPTION 'FAIL [open nicht leer trotz complete]: %', r->'open'; END IF;

  -- ---------- 4) eine finance-Sektion zurueck auf unknown -> kombiniert schliesst, core-only bleibt offen-frei ----------
  PERFORM core.fn_set_onboarding_section('{"package":"finance","section_key":"goals","status":"unknown"}');
  r := core.fn_onboarding_status('finance');
  IF (r->>'complete')::boolean THEN RAISE EXCEPTION 'FAIL [kombiniert complete trotz finance unknown]'; END IF;
  r := core.fn_onboarding_status();    -- core-only: household ist completed
  IF NOT (r->>'complete')::boolean THEN RAISE EXCEPTION 'FAIL [core-only nicht complete trotz household completed]: %', r; END IF;

  -- ---------- 5) skipped zaehlt als aufgeloest + setzt skipped_at ----------
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"goals","status":"skipped"}');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [skip finance goals: %]', r; END IF;
  IF (SELECT skipped_at FROM finance.onboarding_state WHERE section_key='goals') IS NULL THEN
    RAISE EXCEPTION 'FAIL [skipped_at finance nicht gesetzt]'; END IF;
  r := core.fn_onboarding_status('finance');
  IF NOT (r->>'complete')::boolean THEN RAISE EXCEPTION 'FAIL [skipped zaehlt nicht als aufgeloest]: %', r; END IF;

  -- ---------- 6) Write-Guards: unbekannte Sektion / ungueltiger Status / unbekanntes Paket -> {ok:false} ----------
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__nope__","status":"completed"}');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [unbekannte finance-Sektion akzeptiert]'; END IF;
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"accounts","status":"bogus"}');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [ungueltiger Status akzeptiert]'; END IF;
  r := core.fn_set_onboarding_section('{"package":"nonexistent_pkg","section_key":"x","status":"completed"}');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [unbekanntes Paket beim Write akzeptiert]'; END IF;

  -- ---------- 7) Read-Guard (B2): unbekanntes/ungueltiges Paket -> package={ok:false}, complete=false, NIE Fremdtabelle ----------
  r := core.fn_onboarding_status('nonexistent_pkg');
  IF (r->'package'->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [unknown package -> kein ok:false]: %', r->'package'; END IF;
  IF (r->>'complete')::boolean THEN RAISE EXCEPTION 'FAIL [unknown package -> complete muss false]: %', r; END IF;
  r := core.fn_onboarding_status('Bad_Name');   -- Grossbuchstabe -> Regex-Reject
  IF (r->'package'->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [ungueltiger Paketname nicht abgewiesen]: %', r->'package'; END IF;

  RAISE NOTICE 'PASS core.fn_onboarding_status / fn_set_onboarding_section [kombiniert/Tri-State/Gate/Guards]';
END $$;

-- ---------- 8) VF3 (B1): finance_ro liest den Onboarding-Status ueber das publizierte DEFINER-Fenster ----------
-- Beweist, dass die SECURITY-DEFINER-Read-fn die D10-Isolation kontrolliert ueberschreitet (finance_ro hat
-- KEIN SELECT auf agent + sieht das eigene finance nur ueber die fn). Voraussetzung: EXECUTE-Grant aus
-- fn_provision_package_roles (bootstrap_test_db). Superuser -> SET LOCAL ROLE ohne Membership.
DO $$
DECLARE r JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='finance_ro') THEN
    RAISE EXCEPTION 'FAIL VF3 setup: finance_ro nicht provisioniert (bootstrap_test_db / apply_schema Phase 4 pruefen)';
  END IF;
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('accounts',1,'Konten')
    ON CONFLICT (section_key) DO NOTHING;

  SET LOCAL ROLE finance_ro;
  r := core.fn_onboarding_status('finance');
  RESET ROLE;

  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL VF3 [finance_ro konnte die Onboarding-Read-fn nicht aufrufen]: %', r; END IF;
  IF jsonb_typeof(r->'package'->'sections') <> 'object' OR (r->'package'->'sections') = '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL VF3 [finance_ro sah keine finance-Sektionen via DEFINER-Fenster]: %', r; END IF;
  IF jsonb_typeof(r->'core') <> 'object' THEN
    RAISE EXCEPTION 'FAIL VF3 [finance_ro sah das core-Bein nicht (DEFINER cross-schema agent)]: %', r; END IF;
  RAISE NOTICE 'PASS VF3 [finance_ro liest Onboarding-Status ueber das publizierte DEFINER-Fenster]';
END $$;

-- Roter Faden: viewer_is_member = der Fragende (p_chat_id) ist ein aufgeloestes Mitglied (nicht der Owner) -> das
-- Core-first-Gate sagt ihm "der Haushalt wird noch eingerichtet" statt "schick /onboarding". Owner / unbekannt /
-- ohne chat_id -> false. Lesbar unter der engen RO-Rolle (das Gate liest unter <pkg>_ro).
DO $$
DECLARE r jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'viewer fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__vw_owner__','first_name','VW','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7401,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__vw_partner__','first_name','VW','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7402,'as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  SET LOCAL ROLE finance_ro;
  r := core.fn_onboarding_status('core', '7402');
  IF (r->>'viewer_is_member')::boolean IS NOT TRUE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [viewer Mitglied -> true]: %', r; END IF;
  r := core.fn_onboarding_status('core', '7401');
  IF (r->>'viewer_is_member')::boolean IS NOT FALSE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [viewer Owner -> false]: %', r; END IF;
  r := core.fn_onboarding_status('core', '999999');
  IF (r->>'viewer_is_member')::boolean IS NOT FALSE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [viewer unbekannt -> false]: %', r; END IF;
  r := core.fn_onboarding_status('core');
  IF (r->>'viewer_is_member')::boolean IS NOT FALSE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [ohne chat_id -> false]: %', r; END IF;
  RESET ROLE;
  RAISE NOTICE 'PASS [viewer_is_member unter finance_ro]';
END $$;

ROLLBACK;
