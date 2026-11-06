-- tests/db/estate/test_fn_case_template_rows.sql
-- WS-3: der Soll-Task-Satz — Condition-Matrix (adult_subject/finance_absent/minor_children/flags),
--   fan_out je special_asset, event- vs knowledge-Anker, Snapshot-Titel. Self-contained.
BEGIN;

-- Helper: Status EINES Templates aus dem Soll-Satz holen.
DO $$
DECLARE
  v_st TEXT;
  v_cnt INT;
  v_ref TEXT;
  v_due DATE;
  v_asset BIGINT;
BEGIN
  -- Fixture: Haushalt mit Partner (hans, Subjekt), Kind (kid) + Waffe von hans.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222),
      jsonb_build_object('person_id','kid','first_name','Kim','last_name','M','role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO estate.special_assets (owner_person_id, asset_type, description) VALUES ('hans','firearm','Jagdgewehr Merkel')
  RETURNING id INTO v_asset;

  -- ---- unconditional immediate task -> open (death) ----
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'death_certificate';
  IF v_st <> 'open' THEN RAISE EXCEPTION 'FAIL [unconditional death_certificate <> open: %]', v_st; END IF;

  -- ---- finance_absent: finance NICHT registriert -> open ----
  DELETE FROM core.package_registry WHERE package = 'finance';
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'finance_absent_death';
  IF v_st <> 'open' THEN RAISE EXCEPTION 'FAIL [finance absent -> finance_absent_death open, got %]', v_st; END IF;
  -- finance aktiv -> not_applicable
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status = 'active';
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'finance_absent_death';
  IF v_st <> 'not_applicable' THEN RAISE EXCEPTION 'FAIL [finance active -> finance_absent_death n.a., got %]', v_st; END IF;
  RAISE NOTICE 'PASS [Condition finance_absent (beide Zweige)]';

  -- ---- minor_children: Haushalt hat ein Kind -> minor_children_custody open ----
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'minor_children_custody';
  IF v_st <> 'open' THEN RAISE EXCEPTION 'FAIL [minor_children -> open, got %]', v_st; END IF;

  -- ---- adult_subject: Subjekt=Partner -> final_tax_return open; Subjekt=Kind -> n.a. ----
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'final_tax_return';
  IF v_st <> 'open' THEN RAISE EXCEPTION 'FAIL [adult subject -> final_tax_return open, got %]', v_st; END IF;
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','kid','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'final_tax_return';
  IF v_st <> 'not_applicable' THEN RAISE EXCEPTION 'FAIL [child subject -> final_tax_return n.a., got %]', v_st; END IF;
  RAISE NOTICE 'PASS [Condition adult_subject + minor_children]';

  -- ---- flag-Condition tenant: gesetzt -> open, fehlend -> n.a. (sichtbar) ----
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'tenancy';
  IF v_st <> 'not_applicable' THEN RAISE EXCEPTION 'FAIL [tenant absent -> tenancy n.a., got %]', v_st; END IF;
  SELECT status INTO v_st FROM estate.fn_case_template_rows('death','hans','{"tenant":true}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'tenancy';
  IF v_st <> 'open' THEN RAISE EXCEPTION 'FAIL [tenant flag -> tenancy open, got %]', v_st; END IF;
  RAISE NOTICE 'PASS [Condition flag tenant (n.a. sichtbar + open)]';

  -- ---- fan_out firearm: eine Task je Waffe, subject_ref='asset:<id>', Titel ergaenzt ----
  SELECT count(*), min(subject_ref) INTO v_cnt, v_ref FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'secure_firearms';
  IF v_cnt <> 1 OR v_ref <> ('asset:'||v_asset) THEN RAISE EXCEPTION 'FAIL [fan_out firearm: cnt=% ref=%]', v_cnt, v_ref; END IF;
  IF NOT EXISTS (SELECT 1 FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
                 WHERE template_key='secure_firearms' AND title LIKE '%Jagdgewehr Merkel%') THEN
    RAISE EXCEPTION 'FAIL [fan_out Titel nicht um Beschreibung ergaenzt]'; END IF;
  -- Kein Waffen-Stub -> keine Task (nicht n.a.).
  DELETE FROM estate.special_assets WHERE id = v_asset;
  SELECT count(*) INTO v_cnt FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-05-10','2024-05-10','bayern')
    WHERE template_key = 'secure_firearms';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [fan_out ohne Stub -> keine Task, got %]', v_cnt; END IF;
  RAISE NOTICE 'PASS [fan_out je special_asset + 0-Stub-Fall]';

  -- ---- knowledge-Anker: inheritance_refusal = knowledge + 6 Wochen (nicht event) ----
  SELECT due_date INTO v_due FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-01-15','2024-02-01','bayern')
    WHERE template_key = 'inheritance_refusal';
  IF v_due <> ('2024-02-01'::date + 42) THEN RAISE EXCEPTION 'FAIL [§1944 Anker=knowledge: % statt %]', v_due, ('2024-02-01'::date + 42); END IF;
  -- event-Anker: sterbefallanzeige = event + 3 Werktage (nicht knowledge).
  SELECT due_date INTO v_due FROM estate.fn_case_template_rows('death','hans','{}'::jsonb,'2024-01-15','2024-02-01','berlin')
    WHERE template_key = 'sterbefallanzeige';
  IF v_due <> estate.fn_add_business_days('2024-01-15'::date, 3, 'berlin') THEN
    RAISE EXCEPTION 'FAIL [PStG Anker=event: %]', v_due; END IF;
  RAISE NOTICE 'PASS [event- vs knowledge-Anker]';
END $$;

ROLLBACK;
