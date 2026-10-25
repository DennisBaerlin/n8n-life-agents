-- tests/db/estate/test_fn_gap_report.sql
-- WS-2: Gap-Analyse — Erwartungsmenge (essential+recommended je ERWACHSENEM; Kind NIE
-- genudgt; situational NIE), Haushalts-Urkunde deckt BEIDE Erwachsene, Register-Feld-Gaps
-- (death_action/desired_action/Schluesselkonto/fehlende Personen-Zeilen) + konkrete
-- finance-Feld-Gaps (doppel-guardet: aktiv-Pfad UND Absenz-Pfad). Deckt die Views
-- v_directive_gaps + v_register_gaps mit ab. Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
  v_n INT;
  v_fin_status TEXT;
BEGIN
  -- ---------- Fixture: 2 Erwachsene + 1 Kind ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222),
              jsonb_build_object('person_id','kid','first_name','Kim','last_name','Beispiel',
                                 'role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ---------- Leeres Register: Erwartungsmenge = 2 Erwachsene x (3 essential + 2 recommended) ----------
  SELECT count(*) INTO v_n FROM estate.v_directive_gaps;
  IF v_n <> 10 THEN RAISE EXCEPTION 'FAIL [Erwartungsmenge]: % Gaps statt 10 (2 Erwachsene x 5)', v_n; END IF;
  PERFORM 1 FROM estate.v_directive_gaps WHERE person_id = 'kid';
  IF FOUND THEN RAISE EXCEPTION 'FAIL [Kind genudgt]: Minderjaehrigen-Gap gefunden'; END IF;
  PERFORM 1 FROM estate.v_directive_gaps WHERE recommendation = 'situational';
  IF FOUND THEN RAISE EXCEPTION 'FAIL [situational genudgt]'; END IF;
  RAISE NOTICE 'PASS [Erwartungsmenge: 10 Gaps, Kind + situational NIE genudgt]';

  -- ---------- Haushalts-Urkunde deckt BEIDE Erwachsene ----------
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status)
  VALUES (NULL, 'testament', 'exists');
  SELECT count(*) INTO v_n FROM estate.v_directive_gaps;
  IF v_n <> 8 THEN RAISE EXCEPTION 'FAIL [Haushalts-Deckung]: % Gaps statt 8', v_n; END IF;
  RAISE NOTICE 'PASS [Haushalts-Testament exists deckt beide Erwachsene (-2 Gaps)]';

  -- planned bleibt ein sichtbarer Gap (Status im Report):
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status)
  VALUES ('erika', 'vorsorgevollmacht', 'planned');
  PERFORM 1 FROM estate.v_directive_gaps
   WHERE person_id = 'erika' AND doc_type = 'vorsorgevollmacht' AND status = 'planned';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [planned-Gap fehlt]'; END IF;
  SELECT count(*) INTO v_n FROM estate.v_directive_gaps;
  IF v_n <> 8 THEN RAISE EXCEPTION 'FAIL [planned]: % Gaps statt 8', v_n; END IF;
  RAISE NOTICE 'PASS [planned = Gap mit Status (kein Doppel, kein Wegfall)]';

  -- ---------- Register-Feld-Gaps ----------
  INSERT INTO estate.provider_contracts (provider, category) VALUES ('Stadtwerke', 'utilities');   -- death_action NULL
  INSERT INTO estate.digital_accounts (provider, category, is_key_account)
  VALUES ('GMX', 'email', TRUE);                                                                   -- desired_action NULL + Key ohne access_path
  SELECT count(*) INTO v_n FROM estate.v_register_gaps;
  -- 1 (death_action) + 2 (desired_action + Schluesselkonto) + 2 (person_records fehlen) + 2 (funeral fehlt) = 7
  IF v_n <> 7 THEN RAISE EXCEPTION 'FAIL [register gaps]: % statt 7', v_n; END IF;
  INSERT INTO estate.person_records (person_id, employer) VALUES ('erika', 'Beispiel GmbH');   -- Inhalt schliesst die Luecke (WP3)
  SELECT count(*) INTO v_n FROM estate.v_register_gaps;
  IF v_n <> 6 THEN RAISE EXCEPTION 'FAIL [person_record-Gap nicht aufgeloest]: % statt 6', v_n; END IF;
  RAISE NOTICE 'PASS [Register-Feld-Gaps: death_action/desired_action/Schluesselkonto/Personen-Zeilen]';

  -- ---------- finance-Feld-Gaps (aktiv-Pfad; Superuser sieht finance) ----------
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO finance.insurances (name, valid_from, insurance_type)
  VALUES ('__test__ Risikoleben', CURRENT_DATE, 'life');
  INSERT INTO finance.accounts (name, account_type) VALUES ('__test__ Giro', 'cash');

  v_r := estate.fn_gap_report();
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [gap_report]: %', v_r; END IF;
  v_fin_status := v_r->'finance'->>'status';
  IF v_fin_status <> 'ok' THEN RAISE EXCEPTION 'FAIL [finance status]: % statt ok', v_fin_status; END IF;
  -- Risikoleben (life): policy_number + beneficiary + claim_deadline_hours fehlen (insurance_type gesetzt):
  PERFORM 1 FROM jsonb_array_elements(v_r->'finance'->'gaps') g
   WHERE g->>'area' = 'insurance' AND g->>'item' = '__test__ Risikoleben'
     AND g->'missing_fields' ? 'policy_number' AND g->'missing_fields' ? 'beneficiary'
     AND g->'missing_fields' ? 'claim_deadline_hours' AND NOT (g->'missing_fields' ? 'insurance_type');
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [insurance gaps]: %', v_r->'finance'; END IF;
  -- Giro: ownership + has_transmortal_poa offen:
  PERFORM 1 FROM jsonb_array_elements(v_r->'finance'->'gaps') g
   WHERE g->>'area' = 'account' AND g->>'item' = '__test__ Giro'
     AND g->'missing_fields' ? 'ownership' AND g->'missing_fields' ? 'has_transmortal_poa';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [account gaps]: %', v_r->'finance'; END IF;
  -- Aggregat-Zaehler stimmen mit den Views ueberein:
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v_r->'directive_gaps');
  IF v_n <> 8 THEN RAISE EXCEPTION 'FAIL [report directive count]: % statt 8', v_n; END IF;
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v_r->'register_gaps');
  IF v_n <> 6 THEN RAISE EXCEPTION 'FAIL [report register count]: % statt 6', v_n; END IF;
  -- Textkatalog Phase C: jeder Register-Gap traegt einen stabilen gap_code (Anzeige estate.gap.<code>) + englischen
  -- Modelltext (der estate_ro-Leser ist das LLM)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'register_gaps') g
              WHERE g->>'gap_code' NOT IN ('death_action_open', 'digital_action_open', 'key_account_no_access',
                                           'person_record_missing', 'funeral_missing')
                 OR g->>'gap' ~ '[äöüÄÖÜß]' OR g->>'gap' ~* '(nicht|fehlen|erfasst)') THEN
    RAISE EXCEPTION 'FAIL [gap_code/englischer gap]: %', v_r->'register_gaps'; END IF;
  RAISE NOTICE 'PASS [finance-Feld-Gaps: konkrete missing_fields je Police/Konto + Aggregat-Parity]';

  -- Nicht-todesfall-relevante Police: beneficiary/claim_deadline werden NICHT genudgt:
  INSERT INTO finance.insurances (name, valid_from, insurance_type, policy_number)
  VALUES ('__test__ Haftpflicht', CURRENT_DATE, 'liability', 'HP-1');
  v_r := estate.fn_gap_report();
  PERFORM 1 FROM jsonb_array_elements(v_r->'finance'->'gaps') g
   WHERE g->>'item' = '__test__ Haftpflicht';
  IF FOUND THEN RAISE EXCEPTION 'FAIL [Haftpflicht-Rauschen]: beneficiary-Gap fuer liability genudgt'; END IF;
  RAISE NOTICE 'PASS [kein Gap-Rauschen: liability ohne beneficiary/claim-Nudge]';

  -- ---------- Absenz-Pfad (finance inaktiv -> sichtbares status-Feld, nie still) ----------
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  v_r := estate.fn_gap_report();
  IF v_r->'finance'->>'status' <> 'absent' THEN
    RAISE EXCEPTION 'FAIL [Absenz-Pfad]: % statt absent', v_r->'finance'->>'status';
  END IF;
  RAISE NOTICE 'PASS [finance inaktiv -> status absent (sichtbar, nie still)]';
END $$;

ROLLBACK;
