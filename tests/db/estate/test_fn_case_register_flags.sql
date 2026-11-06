-- tests/db/estate/test_fn_case_register_flags.sql
-- WP3: Fall-Merkmale (has_will/no_poa/employed/pension_relevant/tenant) leitet die DB aus dem Vorsorge-Register ab
--   (true | false | null = Register weiss es nicht). Eine Haushalts-Urkunde (owner_person_id NULL) zaehlt nur fuer
--   ein erwachsenes Subjekt; fuer ein Kind sind employed/pension_relevant/tenant/no_poa abgeleitet false.
--   Wirksame Flags in fn_case_template_rows = Register, ueberstimmt von einer expliziten Fall-Angabe.
--   Self-contained (BEGIN..ROLLBACK), erfundene Persona.
BEGIN;

DO $$
DECLARE
  f    JSONB;
  v_st TEXT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222),
      jsonb_build_object('person_id','kid','first_name','Kim','last_name','M','role','child','birth_date','2012-03-10')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ---- leeres Register: alles unbekannt (null) fuer den Erwachsenen ----
  f := estate.fn_case_register_flags('hans');
  IF f IS DISTINCT FROM '{"has_will":null,"no_poa":null,"employed":null,"pension_relevant":null,"tenant":null}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [leeres Register -> alles null: %]', f; END IF;

  -- ---- Kind: employed/pension_relevant/tenant/no_poa abgeleitet false ----
  f := estate.fn_case_register_flags('kid');
  IF f->'employed' IS DISTINCT FROM 'false'::jsonb OR f->'pension_relevant' IS DISTINCT FROM 'false'::jsonb
     OR f->'tenant' IS DISTINCT FROM 'false'::jsonb OR f->'no_poa' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Kind -> false: %]', f; END IF;

  -- ---- has_will: Testament exists (Subjekt) -> true; does_not_exist -> false; Erbvertrag planned -> null ----
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('hans','testament','does_not_exist');
  IF estate.fn_case_register_flags('hans')->'has_will' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Testament does_not_exist -> false]'; END IF;
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('hans','erbvertrag','planned');
  IF estate.fn_case_register_flags('hans')->'has_will' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Erbvertrag planned -> unbekannt]'; END IF;
  UPDATE estate.directives SET doc_status = 'exists' WHERE owner_person_id = 'hans' AND doc_type = 'erbvertrag';
  IF estate.fn_case_register_flags('hans')->'has_will' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Erbvertrag exists -> true]'; END IF;

  -- ---- Haushalts-Testament (Berliner Testament) zaehlt fuer Erwachsene, nicht fuer das Kind ----
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES (NULL,'testament','exists');
  IF estate.fn_case_register_flags('erika')->'has_will' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Haushalts-Testament -> Erwachsene true]'; END IF;
  IF estate.fn_case_register_flags('kid')->'has_will' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Haushalts-Testament zaehlt nicht fuers Kind]'; END IF;

  -- ---- no_poa: Vorsorgevollmacht does_not_exist -> true, exists -> false ----
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('hans','vorsorgevollmacht','does_not_exist');
  IF estate.fn_case_register_flags('hans')->'no_poa' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL [keine Vorsorgevollmacht -> no_poa true]'; END IF;
  UPDATE estate.directives SET doc_status = 'exists' WHERE owner_person_id = 'hans' AND doc_type = 'vorsorgevollmacht';
  IF estate.fn_case_register_flags('hans')->'no_poa' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Vorsorgevollmacht exists -> no_poa false]'; END IF;

  -- ---- employed / pension_relevant aus person_records; employed auch ueber employer_hr-Kontakt ----
  INSERT INTO estate.person_records (person_id, employer, pension_insurance_no) VALUES ('hans', 'Beispiel GmbH', '12345678A123');
  f := estate.fn_case_register_flags('hans');
  IF f->'employed' IS DISTINCT FROM 'true'::jsonb OR f->'pension_relevant' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL [person_records -> employed/pension true: %]', f; END IF;
  INSERT INTO estate.contacts (owner_person_id, role, name) VALUES ('erika', 'employer_hr', 'Personalabteilung X');
  IF estate.fn_case_register_flags('erika')->'employed' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL [employer_hr-Kontakt -> employed true]'; END IF;

  -- ---- tenant ueber Vermieter-Kontakt (Haushalt) ----
  INSERT INTO estate.contacts (owner_person_id, role, name) VALUES (NULL, 'landlord', 'Hausverwaltung Y');
  IF estate.fn_case_register_flags('hans')->'tenant' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Vermieter-Kontakt -> tenant true]'; END IF;
  RAISE NOTICE 'PASS fn_case_register_flags [leer=null, Kind=false, Testament/Erbvertrag, Haushalts-Urkunde, Vollmacht, Stammdaten, Kontakte]';

  -- ---- wirksame Flags in fn_case_template_rows: Register greift, explizite Angabe schlaegt Register ----
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2026-10-20','2026-10-20','bayern')
    WHERE template_key = 'deliver_will';
  IF v_st <> 'open' THEN RAISE EXCEPTION 'FAIL [Register has_will -> deliver_will open, got %]', v_st; END IF;
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2026-10-20','2026-10-20','bayern')
    WHERE template_key = 'tenancy';
  IF v_st <> 'open' THEN RAISE EXCEPTION 'FAIL [Register tenant -> tenancy open, got %]', v_st; END IF;
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{"tenant":false}'::jsonb,'2026-10-20','2026-10-20','bayern')
    WHERE template_key = 'tenancy';
  IF v_st <> 'not_applicable' THEN RAISE EXCEPTION 'FAIL [explizit tenant=false schlaegt Register, got %]', v_st; END IF;
  RAISE NOTICE 'PASS fn_case_template_rows [Register-Flags wirken, explizite Angabe ueberstimmt]';
END $$;

ROLLBACK;
