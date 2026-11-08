-- tests/db/estate/pending_drift_findings.sql
-- PENDING: Drift-Funde (Prompt/Tool-Description <-> fn-Vertrag) im Nachlass-Paket, bewusst ROT und ausserhalb des
-- Gates (db_test sammelt nur test_*.sql). Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_drift_*'
-- Fund-Nummern = Karten-IDs im Drift-Bericht (S<Stufe>.<n>, Stand main 8ff7de43). Eine Transaktion je Fall.

-- (S3.17) Bundesland so, wie Nutzer es schreiben ("Baden-Württemberg"): die Description nennt nur fuenf Slugs, die
--   16 stehen nur im Manifest; der Ablehnungstext nennt zwei. Korrekt: entweder die DB normalisiert die Schreibweise
--   (Umlaut/Bindestrich/Gross -> Slug) oder die Ablehnung nennt alle gueltigen Slugs, damit der zweite Versuch sitzt.
BEGIN;
DO $$
DECLARE v_r jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','Baden-Württemberg'));
  IF NOT (v_r->>'ok')::boolean AND v_r->>'reason' NOT LIKE '%thueringen%' THEN
    RAISE EXCEPTION 'FAIL [S3.17] "Baden-Württemberg" abgelehnt, Ablehnung nennt nicht alle Slugs: %', v_r->>'reason';
  END IF;
  RAISE NOTICE 'PASS [S3.17]';
END $$;
ROLLBACK;
