-- tests/db/finance/test_fn_import_pension_statement.sql
-- Renteninformation-Import (Plan 2026-10-26, Werte erfunden): neue Rohwert-Felder (Entgeltpunkte, Szenarien 1 %/2 %,
-- Regelaltersrenten-Beginn) laufen Stage -> Validate -> Bundle durch; ein Selbstbezug ("ich") im Personenfeld wird
-- beim Staging zum vollen Namen der Person, die gerade chattet; hat diese Person schon eine aktive gesetzliche
-- Rente, entfaellt die neue Renten-Zeile und die Renteninformation haengt sich an die vorhandene.
BEGIN;

DO $$
DECLARE
  v JSONB; v_batch UUID; v_pen INT; v_cnt INT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__ips_own','first_name','Ipso','last_name','Rentner','role','owner',
                                 'birth_date','1980-01-01','as_of','2026-10-26','telegram_user_id',7700001),
              jsonb_build_object('person_id','__ips_par','first_name','Ipsa','last_name','Rentner','role','partner',
                                 'birth_date','1981-01-01','as_of','2026-10-26','telegram_user_id',7700002)))))
  ON CONFLICT (name) DO UPDATE
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));

  -- TEST 1: Rente + Renteninformation in einem Batch, Eigentuemer "ich" = Absender (Partnerin chattet)
  v := finance.fn_import_stage(jsonb_build_object('source','vision','chat_id','7700002','rows', jsonb_build_array(
         jsonb_build_object('entity_type','pension','name','__t_ips DRV','pension_type','statutory',
                            'provider','DRV Bund','owner_person','ich','retirement_start_date','2058-02-01'),
         jsonb_build_object('entity_type','pension_statement','pension','__t_ips DRV','statement_date','2025-07-01',
                            'reached_claim','310,50','projection','1.900,00','scenario_1pct','2.650,00',
                            'scenario_2pct','3.700,00','em_monthly','820,00','earning_points','9,1234',
                            'regular_retirement_date','2058-02-01'))));
  v_batch := (v->>'batch_id')::uuid;
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'invalid')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL import_pension [stage]: %', v; END IF;
  IF (SELECT payload->>'owner_person' FROM finance.import_staging WHERE batch_id = v_batch AND entity_type = 'pension')
     IS DISTINCT FROM 'Ipsa Rentner' THEN
    RAISE EXCEPTION 'FAIL import_pension [ich -> Absender]: %',
      (SELECT payload FROM finance.import_staging WHERE batch_id = v_batch AND entity_type = 'pension'); END IF;
  IF (SELECT (payload->>'earning_points')::numeric FROM finance.import_staging WHERE batch_id = v_batch AND entity_type = 'pension_statement')
     IS DISTINCT FROM 9.1234 THEN
    RAISE EXCEPTION 'FAIL import_pension [Entgeltpunkte normalisiert]'; END IF;
  v := finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL import_pension [bundle]: %', v; END IF;
  SELECT id INTO v_pen FROM finance.pension WHERE name = '__t_ips DRV';
  IF (SELECT owner_person_id FROM finance.pension WHERE id = v_pen) IS DISTINCT FROM '__ips_par'
     OR (SELECT scenario_1pct::text || '|' || scenario_2pct || '|' || earning_points || '|' || regular_retirement_date
         FROM finance.pension_statements WHERE pension_id = v_pen) IS DISTINCT FROM '2650.00|3700.00|9.1234|2058-02-01' THEN
    RAISE EXCEPTION 'FAIL import_pension [gespeichert]: % / %', (SELECT row_to_json(p) FROM finance.pension p WHERE id = v_pen),
      (SELECT row_to_json(s) FROM finance.pension_statements s WHERE pension_id = v_pen); END IF;
  RAISE NOTICE 'PASS import_pension [Rente + Info, ich = wer chattet, neue Felder gespeichert]';

  -- TEST 2: naechstes Jahr wieder "Gesetzliche Rente" + Info -> keine zweite Rente, Info haengt an der vorhandenen
  v := finance.fn_import_stage(jsonb_build_object('source','vision','chat_id','7700002','rows', jsonb_build_array(
         jsonb_build_object('entity_type','pension','name','Gesetzliche Rente','pension_type','statutory','owner_person','Ipsa Rentner'),
         jsonb_build_object('entity_type','pension_statement','pension','Gesetzliche Rente','statement_date','2026-07-01',
                            'reached_claim',340,'projection',1950))));
  v_batch := (v->>'batch_id')::uuid;
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'invalid')::int <> 0
     OR EXISTS (SELECT 1 FROM finance.import_staging WHERE batch_id = v_batch AND entity_type = 'pension')
     OR (SELECT payload->>'pension' FROM finance.import_staging WHERE batch_id = v_batch AND entity_type = 'pension_statement')
        IS DISTINCT FROM '__t_ips DRV' THEN
    RAISE EXCEPTION 'FAIL import_pension [Folgejahr an vorhandene Rente]: % / %', v,
      (SELECT jsonb_agg(payload) FROM finance.import_staging WHERE batch_id = v_batch); END IF;
  v := finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch));
  SELECT count(*) INTO v_cnt FROM finance.pension_statements WHERE pension_id = v_pen;
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR v_cnt <> 2
     OR (SELECT count(*) FROM finance.pension WHERE pension_type = 'statutory' AND owner_person_id = '__ips_par') <> 1 THEN
    RAISE EXCEPTION 'FAIL import_pension [zweite Info gespeichert, eine Rente]: % (Infos %)', v, v_cnt; END IF;
  RAISE NOTICE 'PASS import_pension [Folgejahr: keine zweite gesetzliche Rente, Historie waechst]';

  -- TEST 3: vertauschte Szenarien -> Zeilenfehler vor der Karte (CHECK-Spiegel), kein Abbruch
  v := finance.fn_import_stage(jsonb_build_object('source','vision','chat_id','7700001','rows', jsonb_build_array(
         jsonb_build_object('entity_type','pension_statement','pension','__t_ips DRV','statement_date','2027-07-01',
                            'projection',2000,'scenario_1pct',1500))));
  IF (v->>'invalid')::int <> 1 THEN RAISE EXCEPTION 'FAIL import_pension [Szenario-Plausibilitaet]: %', v; END IF;
  RAISE NOTICE 'PASS import_pension [vertauschte Szenarien -> Zeilenfehler]';

  -- TEST 4: ohne/unbekannte chat_id bleibt "ich" unaufgeloest -> Zeilenfehler wie ein unbekannter Name
  v := finance.fn_import_stage(jsonb_build_object('source','chat','rows', jsonb_build_array(
         jsonb_build_object('entity_type','pension','name','__t_ips bAV','pension_type','occupational','owner_person','ich'))));
  IF (v->>'invalid')::int <> 1 THEN RAISE EXCEPTION 'FAIL import_pension [ich ohne chat_id]: %', v; END IF;
  RAISE NOTICE 'PASS import_pension [ich ohne chat_id -> Zeilenfehler]';
END $$;

ROLLBACK;
