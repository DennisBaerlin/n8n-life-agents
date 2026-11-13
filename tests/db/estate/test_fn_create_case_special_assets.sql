-- tests/db/estate/test_fn_create_case_special_assets.sql
-- Ereignisfall mit im Gespraech genannten Sonderfaellen (Waffe/Tier/Fahrzeug/Firma): fn_create_case legt die Register-
--   Stubs in derselben Transaktion an, die Pflicht-Aufgaben entstehen daraus (Invariante in der DB, nicht im Prompt).
--   fn_preview_case zaehlt die kuenftigen Aufgaben schon mit (Karte = Speicher) und schreibt nichts.
--   Dublette = gleicher Typ + gleiche Beschreibung (lower/trim) bei Person oder Haushalt: kein zweiter Stub.
--   Vorsorgefall: Typen ohne Vorlage fuer den Falltyp werden abgelehnt (genannt => Aufgabe bleibt ehrlich).
-- Werte erfunden. Self-contained.
BEGIN;

DO $$
DECLARE
  v_r JSONB; v_pv JSONB; v_pv0 JSONB; v_case BIGINT; v_n INT; v_n0 INT; v_stubs0 INT; v_ids JSONB; v_ref TEXT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222),
      jsonb_build_object('person_id','oma','first_name','Oma','last_name','M','role','partner','birth_date','1949-02-02'),
      jsonb_build_object('person_id','opa','first_name','Opa','last_name','M','role','partner','birth_date','1947-02-02'),
      jsonb_build_object('person_id','onkel','first_name','Onkel','last_name','M','role','partner','birth_date','1960-02-02'),
      jsonb_build_object('person_id','tante','first_name','Tante','last_name','M','role','partner','birth_date','1962-02-02'),
      jsonb_build_object('person_id','kid','first_name','Kim','last_name','M','role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM estate.special_assets;

  -- ---- (1) Waffe genannt: Preview zaehlt mit und schreibt nichts, Create legt Stub + offene Pflicht-Aufgabe an ----
  v_pv0 := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
             'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern'));
  v_pv  := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
             'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
             'special_assets', jsonb_build_array(jsonb_build_object('asset_type','firearm','description','Beispiel-Jagdwaffe'))));
  IF NOT (v_pv->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [1 Preview ok]: %', v_pv; END IF;
  IF (v_pv->>'total_open')::int <> (v_pv0->>'total_open')::int + 1 THEN
    RAISE EXCEPTION 'FAIL [1 Preview zaehlt die kuenftige Waffen-Aufgabe: ohne %, mit %]', v_pv0->>'total_open', v_pv->>'total_open'; END IF;
  IF jsonb_array_length(v_pv->'special_assets') <> 1 OR v_pv->'special_assets'->0->>'asset_type' <> 'firearm'
     OR v_pv->'special_assets'->0->>'description' <> 'Beispiel-Jagdwaffe' THEN
    RAISE EXCEPTION 'FAIL [1 Preview special_assets fuer die Karte]: %', v_pv->'special_assets'; END IF;
  IF jsonb_array_length(v_pv0->'special_assets') <> 0 THEN RAISE EXCEPTION 'FAIL [1 Preview ohne Angabe: leere Liste]: %', v_pv0; END IF;
  IF (SELECT count(*) FROM estate.special_assets) <> 0 THEN RAISE EXCEPTION 'FAIL [1 Preview darf nichts schreiben]'; END IF;

  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','firearm','description','Beispiel-Jagdwaffe'))));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [1 Create ok]: %', v_r; END IF;
  v_case := (v_r->>'case_id')::bigint;
  IF (v_r->>'total_open')::int <> (v_pv->>'total_open')::int THEN
    RAISE EXCEPTION 'FAIL [1 Karte = Speicher: Preview % <> Create %]', v_pv->>'total_open', v_r->>'total_open'; END IF;
  IF jsonb_array_length(v_r->'special_asset_ids') <> 1 THEN RAISE EXCEPTION 'FAIL [1 special_asset_ids]: %', v_r; END IF;
  IF NOT EXISTS (SELECT 1 FROM estate.special_assets WHERE id = (v_r->'special_asset_ids'->>0)::bigint
                   AND owner_person_id = 'hans' AND asset_type = 'firearm' AND description = 'Beispiel-Jagdwaffe') THEN
    RAISE EXCEPTION 'FAIL [1 Stub: Besitzer = betroffene Person, Typ, Beschreibung]'; END IF;
  SELECT count(*) INTO v_n FROM estate.case_tasks t
   WHERE t.case_id = v_case AND t.status = 'open' AND t.template_key = 'secure_firearms'
     AND t.subject_ref = 'asset:' || (v_r->'special_asset_ids'->>0);
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [1 S2.1 genannte Waffe ohne offene Pflicht-Aufgabe]: %', v_r; END IF;
  RAISE NOTICE 'PASS [1 Waffe genannt: Stub + Aufgabe, Karte = Speicher]';

  -- ---- (2) Haustier + Fahrzeug + Firma zusammen ----
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','oma',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(
             jsonb_build_object('asset_type','pet','description','Beispiel-Kater'),
             jsonb_build_object('asset_type','vehicle','description','Beispiel-Kleinwagen'),
             jsonb_build_object('asset_type','business_interest','description','Beispiel-GmbH-Anteil'))));
  IF NOT (v_r->>'ok')::boolean OR jsonb_array_length(v_r->'special_asset_ids') <> 3 THEN RAISE EXCEPTION 'FAIL [2 drei Typen]: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM estate.case_tasks t
   WHERE t.case_id = (v_r->>'case_id')::bigint AND t.status = 'open' AND t.subject_ref LIKE 'asset:%'
     AND t.template_key IN ('care_pet', 'vehicle_death', 'business_interest_death');
  IF v_n <> 3 THEN RAISE EXCEPTION 'FAIL [2 je Typ eine offene Aufgabe, got %]', v_n; END IF;
  RAISE NOTICE 'PASS [2 Tier + Fahrzeug + Firma]';

  -- ---- (3) zwei Fahrzeuge = zwei Stubs, zwei Aufgaben (unterscheidbar per Beschreibung) ----
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','opa',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(
             jsonb_build_object('asset_type','vehicle','description','Beispiel-Kombi'),
             jsonb_build_object('asset_type','vehicle','description','Beispiel-Roller'))));
  SELECT count(*) INTO v_n FROM estate.case_tasks t WHERE t.case_id = (v_r->>'case_id')::bigint AND t.template_key = 'vehicle_death' AND t.status = 'open';
  IF NOT (v_r->>'ok')::boolean OR v_n <> 2 THEN RAISE EXCEPTION 'FAIL [3 zwei Fahrzeuge -> zwei Aufgaben, got %]: %', v_n, v_r; END IF;
  RAISE NOTICE 'PASS [3 zwei Fahrzeuge]';

  -- ---- (4) Dublette: gleicher Typ + Beschreibung (andere Schreibweise) -> kein zweiter Stub, eine Aufgabe; Haushalts-Stub zaehlt mit ----
  INSERT INTO estate.special_assets (owner_person_id, asset_type, description) VALUES ('onkel','firearm','Jagdgewehr Merkel');
  INSERT INTO estate.special_assets (owner_person_id, asset_type, description) VALUES (NULL,'pet','Haushaltskatze');
  v_stubs0 := (SELECT count(*) FROM estate.special_assets);
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','onkel',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(
             jsonb_build_object('asset_type','firearm','description','  jagdgewehr MERKEL '),
             jsonb_build_object('asset_type','pet','description','haushaltskatze'),
             jsonb_build_object('asset_type','vehicle','description','Beispiel-Lieferwagen'),
             jsonb_build_object('asset_type','vehicle','description','beispiel-lieferwagen'))));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [4 ok]: %', v_r; END IF;
  IF jsonb_array_length(v_r->'special_asset_ids') <> 1 OR (SELECT count(*) FROM estate.special_assets) <> v_stubs0 + 1 THEN
    RAISE EXCEPTION 'FAIL [4 nur der neue Lieferwagen wird angelegt (Dubletten zum Register und innerhalb der Liste entfallen)]: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM estate.case_tasks t WHERE t.case_id = (v_r->>'case_id')::bigint AND t.template_key = 'secure_firearms' AND t.status = 'open';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [4 genau eine Waffen-Aufgabe, got %]', v_n; END IF;
  RAISE NOTICE 'PASS [4 Dublette zum Register und in der Liste]';

  -- ---- (5) ungueltige Eingaben: ok:false, nichts geschrieben ----
  v_stubs0 := (SELECT count(*) FROM estate.special_assets);
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','tante',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','boat','description','Beispiel-Boot'))));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%vehicle | business_interest | firearm | pet%' THEN RAISE EXCEPTION 'FAIL [5a unbekannter Typ]: %', v_r; END IF;
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','tante',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','pet','description','  '))));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%description%' THEN RAISE EXCEPTION 'FAIL [5b leere Beschreibung]: %', v_r; END IF;
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','tante',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern', 'special_assets', jsonb_build_object('asset_type','pet')));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%array%' THEN RAISE EXCEPTION 'FAIL [5c kein Array]: %', v_r; END IF;
  IF (SELECT count(*) FROM estate.special_assets) <> v_stubs0 OR EXISTS (SELECT 1 FROM estate.cases WHERE subject_person_id = 'tante') THEN
    RAISE EXCEPTION 'FAIL [5 Ablehnung schreibt weder Stub noch Fall]'; END IF;
  RAISE NOTICE 'PASS [5 ungueltige Eingaben]';

  -- ---- (6) Kind darf keinen Fall mit Sonderfaellen anlegen (adults_only), nichts geschrieben ----
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','333','case_type','death','subject_person_id','tante',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','pet','description','Beispiel-Hund'))));
  IF (v_r->>'ok')::boolean OR (SELECT count(*) FROM estate.special_assets) <> v_stubs0 THEN RAISE EXCEPTION 'FAIL [6 Kind-Reject]: %', v_r; END IF;
  RAISE NOTICE 'PASS [6 Kind-Reject]';

  -- ---- (7) Vorsorgefall: nur Typen mit Vorlage (Firma); Waffe/Tier/Fahrzeug -> ok:false, nichts geschrieben ----
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','incapacity','subject_person_id','tante',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','firearm','description','Beispiel-Waffe'))));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%no checklist step%' OR v_r->>'reason' NOT LIKE '%tool_create_special_asset%' THEN
    RAISE EXCEPTION 'FAIL [7a Waffe bei Vorsorgefall]: %', v_r; END IF;
  IF (SELECT count(*) FROM estate.special_assets) <> v_stubs0 OR EXISTS (SELECT 1 FROM estate.cases WHERE subject_person_id = 'tante') THEN
    RAISE EXCEPTION 'FAIL [7a nichts geschrieben]'; END IF;
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','incapacity','subject_person_id','tante',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','business_interest','description','Beispiel-GmbH-Anteil'))));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [7b Firma bei Vorsorgefall]: %', v_r; END IF;
  IF NOT EXISTS (SELECT 1 FROM estate.case_tasks t WHERE t.case_id = (v_r->>'case_id')::bigint AND t.template_key = 'business_interest_incap'
                  AND t.status = 'open' AND t.subject_ref LIKE 'asset:%') THEN
    RAISE EXCEPTION 'FAIL [7b Firmen-Aufgabe beim Vorsorgefall]: %', v_r; END IF;
  RAISE NOTICE 'PASS [7 Vorsorgefall: nur Typen mit Vorlage]';

  -- ---- (8) Absage des Falls laesst den Register-Eintrag stehen (der Gegenstand existiert real) ----
  v_ids := v_r->'special_asset_ids';
  PERFORM estate.fn_cancel_case(jsonb_build_object('chat_id','111','case_id', (v_r->>'case_id')::bigint));
  IF NOT EXISTS (SELECT 1 FROM estate.special_assets WHERE id = (v_ids->>0)::bigint) THEN
    RAISE EXCEPTION 'FAIL [8 Eintrag bleibt nach cancel_case]'; END IF;
  RAISE NOTICE 'PASS [8 cancel_case laesst den Eintrag stehen]';

  -- ---- (9) ohne special_assets entsteht kein Stub ----
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','tante',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern'));
  IF NOT (v_r->>'ok')::boolean OR v_r->'special_asset_ids' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [9 ohne Angabe]: %', v_r; END IF;
  RAISE NOTICE 'PASS [9 ohne special_assets unveraendert, special_asset_ids = []]';

  -- ---- (10) offensichtliche Verneinung als Beschreibung ("keine Waffen"): ok:false, nichts geschrieben ----
  v_stubs0 := (SELECT count(*) FROM estate.special_assets);
  FOREACH v_ref IN ARRAY ARRAY['keine', 'Keine Waffen', ' nein ', 'kein Auto', 'None', 'no pets', 'nichts', 'ohne Haustier', '-', 'n/a'] LOOP
    v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','kid',
             'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
             'special_assets', jsonb_build_array(jsonb_build_object('asset_type','firearm','description', v_ref))));
    IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%negation%' THEN
      RAISE EXCEPTION 'FAIL [10 Verneinung "%" muss abgewiesen werden]: %', v_ref, v_r; END IF;
  END LOOP;
  -- echte Beschreibungen, die so aehnlich beginnen, bleiben erlaubt (Kleinwagen, Keiner-Kombi, Nordic-Roller)
  FOREACH v_ref IN ARRAY ARRAY['Kleinwagen', 'Keiner-Kombi', 'Nordic-Roller', 'Nobel-Limousine'] LOOP
    v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','kid',
             'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
             'special_assets', jsonb_build_array(jsonb_build_object('asset_type','vehicle','description', v_ref))));
    IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [10 echte Beschreibung "%" darf nicht abgewiesen werden]: %', v_ref, v_r; END IF;
  END LOOP;
  IF (SELECT count(*) FROM estate.special_assets) <> v_stubs0 THEN RAISE EXCEPTION 'FAIL [10 nichts geschrieben]'; END IF;
  RAISE NOTICE 'PASS [10 Verneinung wird abgewiesen, echte Beschreibung bleibt]';
END $$;

ROLLBACK;
