-- tests/db/core/test_fn_onboarding_overview.sql
-- P1 (Generisches Paket-Onboarding; P2b-1: +p_chat_id): core.fn_onboarding_overview(text DEFAULT NULL) —
--   DAS DB-getriebene Menue-Modell. Dieser Test deckt die GENERISCHE Mechanik (no-arg-Call via Default);
--   die PRO-PERSON-Rendering-Korrektheit (per_user career) deckt test_career_onboarding_person_scoping (TEST 7).
--   DEFINER-Lesefenster, liefert EINE flache, bereits sortierte Sektions-Liste ueber den
--   Core-Haushalt + alle AKTIVEN Pakete (package_registry.status='active') mit <pkg>.onboarding_state.
--   JSON-Shape-Vertrag (TDD-Anker, exakt assertiert): { ok:true, sections:[{package,key,label,status,ord}] }
--   Sortierung: Core-Haushalt zuerst (package='core'), dann Pakete alphabetisch, je Paket nach ord.
--   Der Menue-Builder (core.sub_send_onboarding_menu) liest daraus nur den Status je <package>:<key>; die
--   Anzeige-Reihenfolge legt der Build fest (Get-OnboardingPackageOrder), nicht diese fn.
-- db_test hat KEIN seed_data -> finance/career-Sektionen + package_registry-Zeilen self-seeden. BEGIN..ROLLBACK.
-- Rollen-Perspektive (core_ro EXECUTE) zusaetzlich systematisch in tests/db/cross/test_role_permissions.sql.
BEGIN;

DO $$
DECLARE
  r        JSONB;
  v_secs   JSONB;
  v_first  JSONB;
  v_el     JSONB;
  v_n      INT;
  v_idx_career  INT;
  v_idx_finance INT;
BEGIN
  -- ---------- Setup (Superuser): Core-Haushalt + finance(5) + career(3) + Registry ----------
  -- Core-Haushalt: agent.guide_onboarding_state traegt 'household' (agent.guide_init.sql) -> Status setzen.
  UPDATE agent.guide_onboarding_state SET status='completed' WHERE section_key='household';
  -- Falls die Baseline-Zeile fehlen sollte (defensiv), anlegen:
  INSERT INTO agent.guide_onboarding_state (section_key, ord, label, status)
    VALUES ('household', 1, 'Haushalt & Personen', 'completed') ON CONFLICT (section_key) DO NOTHING;

  -- P2b-1: career.onboarding_state ist pro Person (person_id NOT NULL + FK -> agent.persons). Owner-Fixture +
  -- context_scopes(career=per_user; in db_test NICHT geseedet). Dieser Test prueft die GENERISCHE Overview-Mechanik
  -- (Shape/core-first/Multi-Paket/Reihenfolge/inaktiv/leer/core_ro) mit dem no-arg-Aufruf (career-Katalog als
  -- 'unknown' gerendert -> 3 Sektionen); die PRO-PERSON-Rendering-Korrektheit deckt test_career_onboarding_person_scoping.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
    VALUES ('career_profile','per_user','own_user_only','career') ON CONFLICT (context_name) DO NOTHING;

  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES
    ('accounts',1,'Konten'),('investments',2,'Depot'),('liabilities',3,'Kredite'),
    ('protection',4,'Versicherungen'),('goals',5,'Ziele')
  ON CONFLICT (section_key) DO NOTHING;
  UPDATE finance.onboarding_state SET status='unknown';

  INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES
    ('profile_basics',1,'Aktuelle Rolle & Erfahrung','erika'),('skills_overview',2,'Kompetenzen & Skills','erika'),
    ('goals_targets',3,'Ziel-Rolle & Umstiegs-Timeline','erika')
  ON CONFLICT (section_key, person_id) DO NOTHING;
  UPDATE career.onboarding_state SET status='unknown';

  INSERT INTO core.package_registry (package, version, status) VALUES ('core','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status='active';
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status='active';
  INSERT INTO core.package_registry (package, version, status) VALUES ('career','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status='active';

  -- ---------- (1) Shape-Vertrag: ok=true, sections=Array, jeder Eintrag traegt alle 5 Keys ----------
  r := core.fn_onboarding_overview();
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [(1) ok<>true]: %', r; END IF;
  IF jsonb_typeof(r->'sections') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'FAIL [(1) sections kein Array]: %', r; END IF;
  v_secs := r->'sections';
  FOR v_el IN SELECT e FROM jsonb_array_elements(v_secs) e LOOP
    IF NOT (v_el ? 'package' AND v_el ? 'key' AND v_el ? 'label' AND v_el ? 'status' AND v_el ? 'ord') THEN
      RAISE EXCEPTION 'FAIL [(1) Eintrag ohne package/key/label/status/ord]: %', v_el; END IF;
  END LOOP;

  -- ---------- (2) Core-Haushalt ZUERST (package='core', key='household') ----------
  v_first := v_secs->0;
  IF (v_first->>'package') IS DISTINCT FROM 'core' OR (v_first->>'key') IS DISTINCT FROM 'household' THEN
    RAISE EXCEPTION 'FAIL [(2) erstes Element nicht core/household]: %', v_first; END IF;

  -- ---------- (3) Multi-Paket: core(1) + finance(5) + career(3) = 9 Sektionen ----------
  v_n := jsonb_array_length(v_secs);
  IF v_n <> 9 THEN RAISE EXCEPTION 'FAIL [(3) erwartet 9 Sektionen, war %]: %', v_n, v_secs; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_secs) e WHERE e->>'package'='finance') <> 5 THEN
    RAISE EXCEPTION 'FAIL [(3) finance<>5]: %', v_secs; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_secs) e WHERE e->>'package'='career') <> 3 THEN
    RAISE EXCEPTION 'FAIL [(3) career<>3]: %', v_secs; END IF;

  -- ---------- (4) Paket-Reihenfolge: career VOR finance (alphabetisch, beide nach core) ----------
  SELECT min(ord) - 1 INTO v_idx_career  FROM (SELECT row_number() OVER () AS ord, e FROM jsonb_array_elements(v_secs) e) s WHERE e->>'package'='career';
  SELECT min(ord) - 1 INTO v_idx_finance FROM (SELECT row_number() OVER () AS ord, e FROM jsonb_array_elements(v_secs) e) s WHERE e->>'package'='finance';
  IF v_idx_career >= v_idx_finance THEN
    RAISE EXCEPTION 'FAIL [(4) career nicht vor finance]: career@% finance@%', v_idx_career, v_idx_finance; END IF;
  -- finance-Sektionen nach ord (accounts ord=1 zuerst innerhalb des finance-Blocks)
  IF (SELECT (e->>'key') FROM jsonb_array_elements(v_secs) e WHERE e->>'package'='finance' ORDER BY (e->>'ord')::int LIMIT 1) <> 'accounts' THEN
    RAISE EXCEPTION 'FAIL [(4) finance nicht nach ord sortiert]: %', v_secs; END IF;

  -- ---------- (5) Status wird gespiegelt ----------
  UPDATE finance.onboarding_state SET status='completed' WHERE section_key='accounts';
  r := core.fn_onboarding_overview();
  IF (SELECT (e->>'status') FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='finance' AND e->>'key'='accounts') <> 'completed' THEN
    RAISE EXCEPTION 'FAIL [(5) accounts-Status nicht completed]: %', r; END IF;

  -- ---------- (6) Inaktives Paket ausgeschlossen (finance 'installed') ----------
  UPDATE core.package_registry SET status='installed' WHERE package='finance';
  r := core.fn_onboarding_overview();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='finance') THEN
    RAISE EXCEPTION 'FAIL [(6) inaktives finance in Liste]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='career') THEN
    RAISE EXCEPTION 'FAIL [(6) career fehlt, Schleife abgebrochen?]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='core') THEN
    RAISE EXCEPTION 'FAIL [(6) core fehlt]: %', r; END IF;
  -- (6b) Install-UX-Phase 4: active_packages = die aktiven Paketnamen (≠core, sortiert) -> der Menue-Builder
  --      beschriftet Knoepfe nicht aktiver Pakete ("nicht installiert") statt sie still ins Leere zeigen zu lassen.
  IF jsonb_typeof(r->'active_packages') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'FAIL [(6b) active_packages kein Array]: %', r; END IF;
  IF (r->'active_packages') ? 'finance' OR NOT (r->'active_packages') ? 'career' OR (r->'active_packages') ? 'core' THEN
    RAISE EXCEPTION 'FAIL [(6b) active_packages falsch (erwartet career ohne finance/core)]: %', r->'active_packages'; END IF;
  UPDATE core.package_registry SET status='active' WHERE package='finance';
  r := core.fn_onboarding_overview();
  IF (r->'active_packages') IS DISTINCT FROM '["career","finance"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [(6b) active_packages nicht ["career","finance"]]: %', r->'active_packages'; END IF;

  -- ---------- (7) Leeres onboarding_state (career 0 Zeilen) -> kein Beitrag, KEIN Fehler ----------
  DELETE FROM career.onboarding_state;
  r := core.fn_onboarding_overview();
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [(7) ok<>true bei leerer Tabelle]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='career') THEN
    RAISE EXCEPTION 'FAIL [(7) leeres career liefert Sektionen]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='finance') THEN
    RAISE EXCEPTION 'FAIL [(7) finance fehlt nach leerem career]: %', r; END IF;

  -- ---------- (7b) Betrachter + persoenliche Bereiche (Mitglieder-Menue) ----------
  -- per_user je Sektion (gleiche Regel wie der Handler: core.fn_package_is_per_user) + viewer_role des Tappers.
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES
    ('profile_basics',1,'Aktuelle Rolle & Erfahrung','erika')
  ON CONFLICT (section_key, person_id) DO NOTHING;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', (metadata->'facts'->'persons') ||
    jsonb_build_array(jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                                         'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))
  WHERE name = 'family';
  r := core.fn_onboarding_overview('111');
  IF r->>'viewer_role' IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'FAIL [(7b) viewer_role Owner]: %', r->>'viewer_role'; END IF;
  IF (SELECT bool_and((e->>'per_user')::boolean) FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='career') IS NOT TRUE
     OR (SELECT bool_or((e->>'per_user')::boolean) FROM jsonb_array_elements(r->'sections') e WHERE e->>'package' IN ('core','finance')) IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [(7b) per_user: career true, core/finance false erwartet]: %', r->'sections'; END IF;
  r := core.fn_onboarding_overview('222');
  IF r->>'viewer_role' IS DISTINCT FROM 'partner' THEN RAISE EXCEPTION 'FAIL [(7b) viewer_role Mitglied]: %', r->>'viewer_role'; END IF;
  r := core.fn_onboarding_overview('999');
  IF r ? 'viewer_role' AND r->'viewer_role' <> 'null'::jsonb THEN RAISE EXCEPTION 'FAIL [(7b) viewer_role unbekannt muss null sein]: %', r->'viewer_role'; END IF;

  -- ---------- (8) M3: EXECUTE unter core_ro (der Menue-Read-Pfad, mit chat_id wie im Menue-Sub) ----------
  SET LOCAL ROLE core_ro;
  r := core.fn_onboarding_overview();
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [(8) core_ro ok<>true]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'sections') e WHERE e->>'package'='core' AND e->>'key'='household') THEN
    RAISE EXCEPTION 'FAIL [(8) core_ro sieht core/household nicht]: %', r; END IF;
  r := core.fn_onboarding_overview('111');
  IF r->>'viewer_role' IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'FAIL [(8) core_ro viewer_role]: %', r; END IF;
  RESET ROLE;

  RAISE NOTICE 'PASS core.fn_onboarding_overview [shape/core-first/multi-pkg/order/status/inactive/empty/core_ro]';
END $$;

ROLLBACK;
