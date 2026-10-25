-- tests/db/estate/test_fn_render_estate_overview.sql
-- estate.fn_render_estate_overview: render-at-fetch des EINEN estate-Lese-Kontexts estate_overview
-- (WS-1, Plan groovy-watching-wave). Prueft: leeres Register -> ehrlicher Leer-Hinweis; befuellte
-- Register-Sektionen (Personen-Aufloesung, Gap-Marker OFFEN, Schluesselkonto, Seed-Backup-FUNDORT);
-- finance-Doppel-Guard (fn_package_active + to_regprocedure) beide Halben; DEFINER-Pin-Lauf;
-- Registry-Dispatch via core.fn_fetch_context INKL. der empirischen Scope-Aufloesung (Opus-M5):
-- estate_overview hat KEINE core.context_scopes-Zeile -> household, chat_id suffigiert NIE,
-- agent.fn_context_persons faechert NICHT (leere Menge -> Crons liefen person_id NULL).
BEGIN;
DO $$
DECLARE
  v_hdr TEXT;
  v_c1  TEXT;
  v_c2  TEXT;
  v_sp  BIGINT;
BEGIN
  -- ---------- Fixtures: Personen (Read-Model direkt; FK-Ziel der Register) ----------
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('erika', 'Erika Beispiel', 'owner'),
    ('max',   'Max Beispiel',   'partner')
  ON CONFLICT (person_id) DO NOTHING;

  -- ---------- TEST 1: leeres Register -> ehrlicher Leer-Hinweis, kein NULL ----------
  v_hdr := estate.fn_render_estate_overview('estate_overview');
  IF v_hdr IS NULL THEN RAISE EXCEPTION 'FAIL [1 leer -> NULL statt Leer-Hinweis]'; END IF;
  IF v_hdr NOT LIKE '%estate.register.empty%' THEN
    RAISE EXCEPTION 'FAIL [1 Leer-Hinweis fehlt]: %', v_hdr; END IF;
  -- finance ist im db_test-Substrat NICHT registriert (package_registry leer) -> Absenz-Zeile (Guard-Halbe 1)
  IF v_hdr NOT LIKE '%estate.register.fin_absent%' THEN
    RAISE EXCEPTION 'FAIL [1 finance-Absenz-Zeile fehlt]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [1] leeres Register -> Leer-Hinweis + finance-Absenz-Zeile';

  -- ---------- Fixtures: eine Zeile je Register-Tabelle ----------
  INSERT INTO estate.storage_places (owner_person_id, name, kind, location, access_hint)
  VALUES (NULL, 'Tresor Büro', 'safe', 'Arbeitszimmer', 'Schlüssel im Sekretär');
  INSERT INTO estate.storage_places (owner_person_id, name, kind)
  VALUES ('max', 'Schliessfach Arbeit', 'bank_deposit_box');   -- person-skopierte Fundstelle (Cold-Eyes A m3)
  SELECT id INTO v_sp FROM estate.storage_places WHERE name = 'Tresor Büro';

  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status, form, registry, storage_place_id, authorized_person)
  VALUES ('erika', 'testament', 'exists', 'notariell', 'ztr', v_sp, 'Max Beispiel');
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status)
  VALUES (NULL, 'vorsorgevollmacht', 'planned');

  INSERT INTO estate.provider_contracts (owner_person_id, category, provider, customer_no, death_action)
  VALUES ('erika', 'telecom', 'Telekom', 'KD-123456', NULL);   -- death_action NULL = offener Gap

  INSERT INTO estate.digital_accounts (owner_person_id, category, provider, username, is_key_account, desired_action)
  VALUES ('erika', 'email', 'GMX', 'erika@example.org', TRUE, NULL);
  INSERT INTO estate.digital_accounts (owner_person_id, category, provider, seed_backup_location)
  VALUES ('erika', 'crypto', 'Hardware-Wallet', 'Metallplatte im Tresor');

  INSERT INTO estate.contacts (role, name, organization, phone)
  VALUES ('notary', 'Dr. Muster', 'Notariat Muster', '+49 40 123');

  INSERT INTO estate.person_records (person_id, tax_id, health_insurance_type, health_insurance_name, employer)
  VALUES ('erika', '12345678901', 'gkv', 'TK', 'Beispiel AG');

  INSERT INTO estate.funeral_preferences (person_id, burial_type, has_prepaid_contract)
  VALUES ('erika', 'feuerbestattung', FALSE);

  INSERT INTO estate.special_assets (owner_person_id, asset_type, description)
  VALUES ('max', 'vehicle', 'BMW 3er');

  -- ---------- TEST 2: befuelltes Register -> Sektionen, Personen-Namen, Gap-Marker ----------
  v_hdr := estate.fn_render_estate_overview('estate_overview');
  IF v_hdr LIKE '%estate.register.empty%' THEN RAISE EXCEPTION 'FAIL [2 Leer-Hinweis trotz Daten]'; END IF;
  IF v_hdr NOT LIKE '%Erika Beispiel%Testament%' OR v_hdr NOT LIKE '%notariell%' OR v_hdr NOT LIKE '%ZTR%' THEN
    RAISE EXCEPTION 'FAIL [2 Dokumente-Sektion]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%estate.register.household%Vorsorgevollmacht%' THEN
    RAISE EXCEPTION 'FAIL [2 Haushalts-Dokument (owner_person_id NULL)]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Tresor Büro%' THEN
    RAISE EXCEPTION 'FAIL [2 Fundort-Auflösung]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Schliessfach Arbeit (bank_deposit_box, Max Beispiel)%' THEN
    RAISE EXCEPTION 'FAIL [2 person-skopierte Fundstelle mit Eigentümer]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Telekom%' OR v_hdr NOT LIKE '%KD-123456%' OR v_hdr NOT LIKE '%estate.register.death_action: estate.register.open%' THEN
    RAISE EXCEPTION 'FAIL [2 Vertrags-Sektion + OFFEN-Gap]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%GMX%' OR v_hdr NOT LIKE '%estate.register.key_account%' THEN
    RAISE EXCEPTION 'FAIL [2 Digital-Sektion + Schlüsselkonto-Marker]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%estate.register.seed_location: Metallplatte im Tresor%' THEN
    RAISE EXCEPTION 'FAIL [2 Seed-Backup-FUNDORT (nie das Geheimnis)]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Dr. Muster%' THEN RAISE EXCEPTION 'FAIL [2 Kontakte-Sektion]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%12345678901%' OR v_hdr NOT LIKE '%TK%' THEN
    RAISE EXCEPTION 'FAIL [2 Stammdaten-Sektion]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Feuerbestattung%' THEN RAISE EXCEPTION 'FAIL [2 Bestattungs-Sektion]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%estate.register.asset_vehicle%BMW 3er%' THEN RAISE EXCEPTION 'FAIL [2 Sonderfall-Sektion]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [2] Register-Sektionen + Personen-Auflösung + Gap-/Schlüssel-Marker';

  -- ---------- TEST 3: finance aktiv -> Register-Zeilen aus den WS-0b-Lese-fns ----------
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO finance.accounts (name, account_type, bank, ownership, has_transmortal_poa)
  VALUES ('Gemeinschaftskonto', 'cash', 'DKB', 'joint_or', TRUE);
  INSERT INTO finance.insurances (name, insurance_company, valid_from, insurance_type, beneficiary, claim_deadline_hours)
  VALUES ('Risiko-LV Erika', 'Allianz', CURRENT_DATE, 'life', 'Max Beispiel', 72);

  v_hdr := estate.fn_render_estate_overview('estate_overview');
  IF v_hdr LIKE '%estate.register.fin_absent%' THEN
    RAISE EXCEPTION 'FAIL [3 Absenz-Zeile trotz aktivem finance]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Risiko-LV Erika%' OR v_hdr NOT LIKE '%Max Beispiel%' OR v_hdr NOT LIKE '%72%' THEN
    RAISE EXCEPTION 'FAIL [3 Versicherungs-Register]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Gemeinschaftskonto%' OR v_hdr NOT LIKE '%joint_or%' OR v_hdr NOT LIKE '%estate.register.transmortal_poa: estate.register.yes%' THEN
    RAISE EXCEPTION 'FAIL [3 Konten-Register]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [3] finance aktiv -> Versicherungs-/Konten-Register-Zeilen';

  -- ---------- TEST 4: Guard-Halbe 2 (to_regprocedure) — fn weg trotz aktivem Paket -> kein Crash ----------
  DROP FUNCTION finance.fn_insurance_register();
  v_hdr := estate.fn_render_estate_overview('estate_overview');
  IF v_hdr IS NULL THEN RAISE EXCEPTION 'FAIL [4 Crash/NULL bei fehlender Provider-fn]'; END IF;
  IF v_hdr NOT LIKE '%Gemeinschaftskonto%' THEN
    RAISE EXCEPTION 'FAIL [4 übrige Register-fns müssen weiterlaufen]: %', v_hdr; END IF;
  IF v_hdr LIKE '%Risiko-LV Erika%' THEN
    RAISE EXCEPTION 'FAIL [4 Versicherungs-Zeile trotz gedroppter fn]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [4] to_regprocedure-Guard: fehlende Provider-fn degradiert graceful';

  -- ---------- TEST 5: Render unter dem Produktions-DEFINER-Pin (kein estate im search_path) ----------
  SET LOCAL search_path = pg_catalog, agent, core;
  v_hdr := estate.fn_render_estate_overview('estate_overview');
  IF v_hdr IS NULL OR v_hdr NOT LIKE '%Erika Beispiel%Testament%' THEN
    RAISE EXCEPTION 'FAIL [5 Render unter DEFINER-Pin]: %', v_hdr; END IF;
  RESET search_path;
  RAISE NOTICE 'PASS [5] alle Referenzen schema-qualifiziert (DEFINER-Pin-Lauf)';

  -- ---------- TEST 6: Registry-Dispatch + Scope-Fan-out (Opus-M5, empirisch) ----------
  -- estate_overview hat KEINE core.context_scopes-Zeile -> household: fn_fetch_context darf mit
  -- numerischer chat_id NIE suffigieren (identischer Content wie ohne chat_id), fn_context_persons
  -- faechert NICHT (leere Menge -> die kuenftigen WS-4-Crons liefen person_id NULL).
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package)
  VALUES ('estate_overview', 't', 'estate_advisor', 'lazy', 'prose-body', 'seed', 'estate');
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('estate_overview', 'estate.fn_render_estate_overview', 'estate')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn;

  SELECT content INTO v_c1 FROM core.fn_fetch_context('estate_overview', NULL);
  IF v_c1 IS NULL OR v_c1 NOT LIKE '%Authoritative facts%' OR v_c1 NOT LIKE '%prose-body%'
     OR v_c1 NOT LIKE '%Erika Beispiel%Testament%' THEN
    RAISE EXCEPTION 'FAIL [6 fetch-Dispatch (Banner+Header+Prosa)]: %', left(COALESCE(v_c1, 'NULL'), 200); END IF;
  SELECT content INTO v_c2 FROM core.fn_fetch_context('estate_overview', '999123');
  IF v_c2 IS DISTINCT FROM v_c1 THEN
    RAISE EXCEPTION 'FAIL [6 household: chat_id darf NICHT suffigieren/fail-closen]'; END IF;
  IF EXISTS (SELECT 1 FROM agent.fn_context_persons('estate_overview')) THEN
    RAISE EXCEPTION 'FAIL [6 fn_context_persons muss leer sein (household, kein Suffix)]'; END IF;
  RAISE NOTICE 'PASS [6] Registry-Dispatch + household-Scope ohne context_scopes-Zeile (M5 verifiziert)';
END $$;
ROLLBACK;
