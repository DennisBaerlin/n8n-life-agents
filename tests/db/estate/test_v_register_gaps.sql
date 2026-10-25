-- tests/db/estate/test_v_register_gaps.sql
-- WP3: die Personen-Luecken in estate.v_register_gaps pruefen den INHALT, nicht die Zeilen-Existenz — der Review-
--   Stempel (fn_confirm_review) legt eine leere person_records-Zeile an, die die Luecke frueher still schloss.
--   Self-contained (BEGIN..ROLLBACK), erfundene Persona.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  IF NOT EXISTS (SELECT 1 FROM estate.v_register_gaps WHERE person_id='erika' AND gap_code='person_record_missing')
     OR NOT EXISTS (SELECT 1 FROM estate.v_register_gaps WHERE person_id='erika' AND gap_code='funeral_missing') THEN
    RAISE EXCEPTION 'FAIL [ohne Zeilen: beide Luecken erwartet]'; END IF;

  -- Review-Stempel legt eine LEERE Stammdaten-Zeile an -> Luecke bleibt
  v_r := estate.fn_confirm_review(jsonb_build_object('chat_id','111','person_id','erika'));
  IF NOT EXISTS (SELECT 1 FROM estate.person_records WHERE person_id='erika') THEN
    RAISE EXCEPTION 'FAIL [Fixture: confirm_review hat keine Zeile angelegt: %]', v_r; END IF;
  IF NOT EXISTS (SELECT 1 FROM estate.v_register_gaps WHERE person_id='erika' AND gap_code='person_record_missing') THEN
    RAISE EXCEPTION 'FAIL [leere Stammdaten-Zeile schliesst die Luecke still]'; END IF;
  INSERT INTO estate.funeral_preferences (person_id) VALUES ('erika');
  IF NOT EXISTS (SELECT 1 FROM estate.v_register_gaps WHERE person_id='erika' AND gap_code='funeral_missing') THEN
    RAISE EXCEPTION 'FAIL [leere Bestattungs-Zeile schliesst die Luecke still]'; END IF;

  -- echter Inhalt schliesst die Luecken
  UPDATE estate.person_records SET certificates_location = 'Ordner Urkunden, Arbeitszimmer' WHERE person_id='erika';
  UPDATE estate.funeral_preferences SET burial_type = 'feuerbestattung' WHERE person_id='erika';
  IF EXISTS (SELECT 1 FROM estate.v_register_gaps WHERE person_id='erika'
              AND gap_code IN ('person_record_missing','funeral_missing')) THEN
    RAISE EXCEPTION 'FAIL [Inhalt schliesst die Luecken nicht]'; END IF;
  RAISE NOTICE 'PASS v_register_gaps [Personen-Luecken nach Inhalt, leere Review-Zeile zaehlt nicht]';
END $$;

ROLLBACK;
