-- tests/db/finance/test_fn_entity_name_report.sql
-- Namens-Regel der finance-Anlagen: Dublette (ohne Gross/Klein, Leerzeichen) lehnt die fn selbst ab, und zwar schon im
-- Probelauf vor der Karte (core.fn_dry_run) mit den vergebenen Namen derselben Art; aehnliche Namen stehen als
-- Kartenzeile; die zweite Person derselben Art bekommt den Namens-Aufbau des Geschwisters (suggested_name).
-- Jeder Fall laeuft in einem eigenen Block, am Ende stehen alle Fehlschlaege in einer Meldung.
BEGIN;

DO $$
DECLARE
  v       JSONB;
  v_fail  TEXT[] := ARRAY[]::text[];
  v_cash  INT;
  v_pot   INT;
  v_batch UUID;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__nm_erika','first_name','Erika','last_name','Mustermann','role','owner',
                                 'birth_date','1980-05-20','telegram_user_id',7710001),
              jsonb_build_object('person_id','__nm_max','first_name','Max','last_name','Mustermann','role','partner',
                                 'birth_date','1981-06-21','telegram_user_id',7710002)))))
  ON CONFLICT (name) DO UPDATE
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));

  v_cash := (finance.fn_create_account('{"name":"__nm Ahorn Giro","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__nm Ahorn Tagesgeld","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

  -- F1 Konto: Dublette anders geschrieben -> ok:false duplicate_name im Probelauf, mit vergebenen Namen der Art
  v := core.fn_dry_run('finance.fn_create_account(jsonb)'::regprocedure,
                       '{"name":"__NM  ahorn giro ","account_type":"cash","currency":"EUR"}'::jsonb);
  IF (v->>'ok')::boolean OR v->>'code' IS DISTINCT FROM 'duplicate_name' THEN v_fail := v_fail || ('F1 Konto-Dublette: ' || v::text); END IF;
  IF NOT (COALESCE(v->'existing_names','[]') @> '["__nm Ahorn Tagesgeld"]') THEN v_fail := v_fail || ('F1b Konto existing_names: ' || v::text); END IF;

  -- F2 Rente (privat): Dublette ohne Gross/Klein
  PERFORM finance.fn_create_pension('{"name":"__nm Riester Erika","pension_type":"riester","provider":"Eichen"}'::jsonb);
  v := core.fn_dry_run('finance.fn_create_pension(jsonb)'::regprocedure,
                       '{"name":"__nm riester erika","pension_type":"riester","provider":"Eichen"}'::jsonb);
  IF (v->>'ok')::boolean OR v->>'code' IS DISTINCT FROM 'duplicate_name'
     OR NOT (COALESCE(v->'existing_names','[]') @> '["__nm Riester Erika"]') THEN v_fail := v_fail || ('F2 Rente-Dublette: ' || v::text); END IF;

  -- F3 Versicherung
  PERFORM finance.fn_create_insurance('{"name":"__nm Haftpflicht","insurance_company":"Buchen AG"}'::jsonb);
  v := core.fn_dry_run('finance.fn_create_insurance(jsonb)'::regprocedure,
                       '{"name":"__NM HAFTPFLICHT","insurance_company":"Linden AG"}'::jsonb);
  IF (v->>'ok')::boolean OR v->>'code' IS DISTINCT FROM 'duplicate_name' THEN v_fail := v_fail || ('F3 Versicherung-Dublette: ' || v::text); END IF;

  -- F4 Kredit
  PERFORM finance.fn_create_loan(jsonb_build_object('name','__nm Autokredit','lender','Kiefer Bank','original_amount',10000,
    'disbursement_date','2026-01-15','interest_rate','3.0','monthly_annuity',300,'schedule_day_of_month','15',
    'first_payment_date','2026-02-15','debit_account_id',v_cash));
  v := core.fn_dry_run('finance.fn_create_loan(jsonb)'::regprocedure, jsonb_build_object('name','__nm autokredit ',
    'lender','Kiefer Bank','original_amount',5000,'disbursement_date','2026-01-15','interest_rate','3.0','monthly_annuity',200,
    'schedule_day_of_month','15','first_payment_date','2026-02-15','debit_account_id',v_cash));
  IF (v->>'ok')::boolean OR v->>'code' IS DISTINCT FROM 'duplicate_name' THEN v_fail := v_fail || ('F4 Kredit-Dublette: ' || v::text); END IF;

  -- F5 Immobilie
  PERFORM finance.fn_create_real_estate('{"name":"__nm Wohnung Hafen"}'::jsonb);
  v := core.fn_dry_run('finance.fn_create_real_estate(jsonb)'::regprocedure, '{"name":"__nm wohnung hafen"}'::jsonb);
  IF (v->>'ok')::boolean OR v->>'code' IS DISTINCT FROM 'duplicate_name' THEN v_fail := v_fail || ('F5 Immobilie-Dublette: ' || v::text); END IF;

  -- F6 Sparziel (normaler Pfad)
  PERFORM finance.fn_create_savings_goal(jsonb_build_object('name','__nm Urlaub','goal_type','vacation','target_amount',1200,
    'target_date','2028-01-01','account_id',v_cash,'reserve_account_id',v_pot,'first_payment_date','2027-01-01'));
  v := core.fn_dry_run('finance.fn_create_savings_goal(jsonb)'::regprocedure, jsonb_build_object('name','__NM urlaub',
    'goal_type','vacation','target_amount',600,'target_date','2028-01-01','account_id',v_cash,'reserve_account_id',v_pot,
    'first_payment_date','2027-01-01'));
  IF (v->>'ok')::boolean OR v->>'code' IS DISTINCT FROM 'name_exists' THEN v_fail := v_fail || ('F6 Sparziel-Dublette: ' || v::text); END IF;

  -- F7 gleicher Name, andere Art -> erlaubt (Namen sind je Art eindeutig, ausser Konten)
  v := core.fn_dry_run('finance.fn_create_pension(jsonb)'::regprocedure,
                       '{"name":"__nm Haftpflicht","pension_type":"private","provider":"Eichen"}'::jsonb);
  IF NOT (v->>'ok')::boolean THEN v_fail := v_fail || ('F7 andere Art erlaubt: ' || v::text); END IF;

  -- F8 ok:true traegt die vergebenen und die aehnlichen Namen; aehnlich -> Kartenzeile similar_entry
  v := core.fn_dry_run('finance.fn_create_pension(jsonb)'::regprocedure,
                       '{"name":"__nm Riester","pension_type":"riester","provider":"Eichen"}'::jsonb);
  IF NOT (v->>'ok')::boolean OR NOT (COALESCE(v->'existing_names','[]') @> '["__nm Riester Erika"]')
     OR NOT (COALESCE(v->'similar_names','[]') @> '["__nm Riester Erika"]')
     OR NOT (COALESCE(v->'card_lines','[]') @> '[{"value":"finance.note.similar_entry","params":{"name":"__nm Riester Erika"}}]') THEN
    v_fail := v_fail || ('F8 existing/similar im ok:true: ' || v::text); END IF;

  -- F9 Ausloeser: zweite gesetzliche Rente im Haushalt ohne Personen-Zusatz -> Konflikt vor der Karte + Vorschlag im
  --    Aufbau der ersten (voller Name)
  PERFORM finance.fn_create_pension('{"name":"__nm Gesetzliche Rente Erika Mustermann","pension_type":"statutory","owner_person_id":"__nm_erika"}'::jsonb);
  v := core.fn_dry_run('finance.fn_create_pension(jsonb)'::regprocedure,
                       '{"name":"__nm Gesetzliche Rente","pension_type":"statutory","owner_person_id":"__nm_max"}'::jsonb);
  IF (v->>'ok')::boolean OR v->>'code' IS DISTINCT FROM 'name_needs_person'
     OR v->>'suggested_name' IS DISTINCT FROM '__nm Gesetzliche Rente Max Mustermann' THEN
    v_fail := v_fail || ('F9 Geschwister-Regel direkt: ' || v::text); END IF;
  --    mit dem Vorschlag geht es durch
  v := core.fn_dry_run('finance.fn_create_pension(jsonb)'::regprocedure,
                       '{"name":"__nm Gesetzliche Rente Max Mustermann","pension_type":"statutory","owner_person_id":"__nm_max"}'::jsonb);
  IF NOT (v->>'ok')::boolean THEN v_fail := v_fail || ('F9b Vorschlag geht durch: ' || v::text); END IF;

  -- F10 Import: dieselbe Rente als Dokument -> die Staging-Zeile bekommt denselben Aufbau, die Renteninformation zieht mit
  v := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
         jsonb_build_object('entity_type','pension','name','__nm Gesetzliche Rente','pension_type','statutory','owner_person','Max Mustermann'),
         jsonb_build_object('entity_type','pension_statement','pension','__nm Gesetzliche Rente','statement_date','2026-07-01','reached_claim',300))));
  v_batch := (v->>'batch_id')::uuid;
  IF (v->>'invalid')::int <> 0
     OR (SELECT payload->>'name' FROM finance.import_staging WHERE batch_id = v_batch AND entity_type = 'pension')
        IS DISTINCT FROM '__nm Gesetzliche Rente Max Mustermann'
     OR (SELECT payload->>'pension' FROM finance.import_staging WHERE batch_id = v_batch AND entity_type = 'pension_statement')
        IS DISTINCT FROM '__nm Gesetzliche Rente Max Mustermann' THEN
    v_fail := v_fail || ('F10 Import-Geschwister-Regel: ' || v::text || ' / '
              || (SELECT jsonb_agg(payload)::text FROM finance.import_staging WHERE batch_id = v_batch)); END IF;

  -- F11 Import-Dublette gegen aktive Rente anders geschrieben -> Zeilenfehler vor der Karte (Beleg: heute schon so)
  v := finance.fn_import_stage(jsonb_build_object('source','chat','rows', jsonb_build_array(
         jsonb_build_object('entity_type','pension','name','__NM RIESTER ERIKA','pension_type','riester'))));
  IF (v->>'invalid')::int <> 1 THEN v_fail := v_fail || ('F11 Import-Dublette aktiv: ' || v::text); END IF;

  -- F12 Import und direkt vergleichen gleich: ein pausierter Eintrag sperrt den Namen in keinem Weg
  INSERT INTO finance.pension (name, pension_type, status) VALUES ('__nm Alt Ruerup', 'ruerup', 'paused');
  v := core.fn_dry_run('finance.fn_create_pension(jsonb)'::regprocedure, '{"name":"__nm Alt Ruerup","pension_type":"ruerup"}'::jsonb);
  IF NOT (v->>'ok')::boolean THEN v_fail := v_fail || ('F12a direkt nach pausiert: ' || v::text); END IF;
  v := finance.fn_import_stage(jsonb_build_object('source','chat','rows', jsonb_build_array(
         jsonb_build_object('entity_type','pension','name','__nm Alt Ruerup','pension_type','ruerup'))));
  IF (v->>'invalid')::int <> 0 THEN v_fail := v_fail || ('F12b Import nach pausiert: ' || v::text); END IF;

  -- F14 Import, andere Art (Versicherung, Vornamen-Form): Geschwister "__nm Hausrat Erika" -> "__nm Hausrat Max"
  PERFORM finance.fn_create_insurance('{"name":"__nm Hausrat Erika","insurance_company":"Buchen AG","policyholder_person_id":"__nm_erika"}'::jsonb);
  v := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
         jsonb_build_object('entity_type','insurance','name','__nm Hausrat','insurance_company','Linden AG','policyholder_person','Max Mustermann'))));
  v_batch := (v->>'batch_id')::uuid;
  IF (v->>'invalid')::int <> 0
     OR (SELECT payload->>'name' FROM finance.import_staging WHERE batch_id = v_batch) IS DISTINCT FROM '__nm Hausrat Max' THEN
    v_fail := v_fail || ('F14 Import Versicherung Vorname: ' || v::text); END IF;

  -- F15 Import-Dublette mit Person: der Zeilenfehler nennt die vergebenen Namen und den Vorschlag
  v := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
         jsonb_build_object('entity_type','insurance','name','__NM haftpflicht','insurance_company','Linden AG','policyholder_person','Max Mustermann'))));
  IF (v->>'invalid')::int <> 1 OR position('suggestion: "__NM haftpflicht Max"' IN v->'errors'->0->>'error') = 0
     OR position('"__nm Haftpflicht"' IN v->'errors'->0->>'error') = 0 THEN
    v_fail := v_fail || ('F15 Import-Zeilenfehler mit Vorschlag: ' || v::text); END IF;

  -- F13 Rollen-Perspektive: der Probelauf laeuft im Werkzeug unter finance_rw (Helfer core.fn_name_report,
  --     core.fn_household_persons) und meldet die Dublette dort genauso
  SET LOCAL ROLE finance_rw;
  v := core.fn_dry_run('finance.fn_create_pension(jsonb)'::regprocedure,
                       '{"name":"__nm Gesetzliche Rente","pension_type":"statutory","owner_person_id":"__nm_max"}'::jsonb);
  RESET ROLE;
  IF v->>'code' IS DISTINCT FROM 'name_needs_person' THEN v_fail := v_fail || ('F13 finance_rw: ' || v::text); END IF;

  IF cardinality(v_fail) > 0 THEN
    RAISE EXCEPTION 'FAIL entity_name_report (% Faelle): %', cardinality(v_fail), array_to_string(v_fail, ' ||| ');
  END IF;
  RAISE NOTICE 'PASS entity_name_report [F1-F12]';
END $$;

ROLLBACK;
