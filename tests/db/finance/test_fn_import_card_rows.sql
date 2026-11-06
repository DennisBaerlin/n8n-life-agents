-- tests/db/finance/test_fn_import_card_rows.sql
-- Testet fn_import_card_rows: die Zeilen der Import-Bestaetigungskarte — je VALIDER Staging-Zeile der rohe Payload
-- plus die abgeleiteten Werte (x), die das Einzel-Tool vor seiner Karte aus denselben fn_* holt: Personenname,
-- Zeilen-Waehrung, Zins-Vorschlag, Rate je Abbuchung, Sparplan, Verrechnungskonto einer Depot-Position und die
-- Defaults, die fn_import_bundle setzt (Datum heute, nominal = ja). Leerer Batch -> [].
BEGIN;

DO $$
DECLARE
  v_res   JSONB;
  v_batch UUID;
  v_rows  JSONB;
  v_r     JSONB;
  v_acct  INT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__icr_p','first_name','Icra','last_name','Kartentest',
                                 'role','owner','birth_date','1980-01-01','as_of','2026-10-22')))))
  ON CONFLICT (name) DO UPDATE
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));

  -- Bestand: Verrechnungskonto + Depot (Depot-Position gegen ein BESTEHENDES Depot)
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__test_icr Alt-Giro', 'cash', 'EUR') RETURNING id INTO v_acct;
  INSERT INTO finance.accounts (name, account_type, currency, settlement_account_id)
  VALUES ('__test_icr Alt-Depot', 'stocks_depot', 'EUR', v_acct);

  v_res := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__test_icr Tagesgeld','account_type','cash',
                       'owner_person','Icra Kartentest','opening_balance',100,'interest_rate',2,'interest_credit_unit','month'),
    jsonb_build_object('entity_type','account','name','__test_icr Depot','account_type','stocks_depot',
                       'settlement_account','__test_icr Tagesgeld'),
    jsonb_build_object('entity_type','stock_buy','depot','__test_icr Depot','symbol','VWCE','isin','IE00BK5BQT80',
                       'shares',3,'price_per_share',100),
    jsonb_build_object('entity_type','stock_buy','depot','__test_icr Alt-Depot','symbol','AAPL','isin','US0378331005',
                       'shares',1,'price_per_share',150,'quote_currency','usd','transaction_date','2026-01-15'),
    jsonb_build_object('entity_type','insurance','name','__test_icr Haftpflicht','annual_premium',120,
                       'debit_account','__test_icr Tagesgeld','first_payment_date','2026-02-01',
                       'schedule_unit','month','policyholder_person','Icra Kartentest'),
    jsonb_build_object('entity_type','savings_goal','name','__test_icr Urlaub','target_amount',1000,
                       'account','__test_icr Alt-Giro','reserve_account','__test_icr Tagesgeld',
                       'first_payment_date','2026-01-01','monthly_savings_rate',100),
    jsonb_build_object('entity_type','pension','name','__test_icr Rente','pension_type','statutory'),
    jsonb_build_object('entity_type','pension_statement','pension','__test_icr Rente','statement_date','2026-01-01',
                       'reached_claim',500),
    jsonb_build_object('entity_type','recurring_payment','name','__test_icr Gehalt','direction','income','amount',3000,
                       'account','__test_icr Tagesgeld','schedule_unit','month','first_payment_date','2026-01-01')
  )));
  IF (v_res->>'valid')::int IS DISTINCT FROM 9 THEN
    RAISE EXCEPTION 'FAIL [fixture]: erwartet 9 valid, got % / %', v_res,
      (SELECT jsonb_agg(jsonb_build_object('row', row_no, 'err', validation_error)) FROM finance.import_staging
       WHERE batch_id = (v_res->>'batch_id')::uuid AND status = 'invalid');
  END IF;
  v_batch := (v_res->>'batch_id')::uuid;
  v_rows := finance.fn_import_card_rows(v_batch);

  IF jsonb_typeof(v_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(v_rows) <> 9
     OR (v_rows->0->>'row_no')::int <> 1 OR (v_rows->8->>'row_no')::int <> 9 THEN
    RAISE EXCEPTION 'FAIL [form]: erwartet 9 Zeilen in row_no-Reihenfolge, got %', v_rows;
  END IF;
  RAISE NOTICE 'PASS fn_import_card_rows [jsonb-Array, alle validen Zeilen, sortiert]';

  -- Konto: Name, Person, Waehrung, Zins-Vorschlag aus fn_account_interest_defaults
  v_r := v_rows->0;
  IF v_r->>'entity_type' IS DISTINCT FROM 'account' OR v_r->>'name' IS DISTINCT FROM '__test_icr Tagesgeld'
     OR v_r->'p'->>'owner_person' IS DISTINCT FROM 'Icra Kartentest'
     OR v_r->'x'->>'person' IS DISTINCT FROM 'Icra Kartentest'
     OR v_r->'x'->>'ccy' IS DISTINCT FROM 'EUR'
     OR v_r->'x'->'interest' IS DISTINCT FROM finance.fn_account_interest_defaults(v_r->'p') THEN
    RAISE EXCEPTION 'FAIL [account]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_import_card_rows [account: Person, Waehrung, Zins-Vorschlag = fn_account_interest_defaults]';

  -- Depot-Position im Batch-Depot: Verrechnungskonto aus der Batch-Zeile, Datum = heute (Bundle-Default)
  v_r := v_rows->2;
  IF v_r->'x'->>'settlement' IS DISTINCT FROM '__test_icr Tagesgeld'
     OR v_r->'x'->>'ccy' IS DISTINCT FROM 'EUR'
     OR v_r->'x'->>'transaction_date' IS DISTINCT FROM to_char(CURRENT_DATE, 'YYYY-MM-DD')
     OR v_r->>'name' IS DISTINCT FROM 'VWCE' THEN
    RAISE EXCEPTION 'FAIL [stock_buy batch-depot]: %', v_r;
  END IF;
  -- Depot-Position im Bestandsdepot: Verrechnungskonto aus dem Bestand, quote_currency schlaegt die Depot-Waehrung
  v_r := v_rows->3;
  IF v_r->'x'->>'settlement' IS DISTINCT FROM '__test_icr Alt-Giro'
     OR v_r->'x'->>'ccy' IS DISTINCT FROM 'USD'
     OR v_r->'x'->>'transaction_date' IS DISTINCT FROM '2026-01-15' THEN
    RAISE EXCEPTION 'FAIL [stock_buy bestand]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_import_card_rows [stock_buy: Verrechnungskonto Batch/Bestand, quote_currency, Datum-Default]';

  -- Herkunft des Verrechnungskontos (settlement_ref, fn_import_ref_account): 'batch' = wird mit angelegt,
  -- 'db' = besteht schon (Owner 2026-10-23: Karte zeigte nur den Namen, las sich wie eine Neuanlage)
  IF v_rows->1->'x'->>'settlement_ref' IS DISTINCT FROM 'batch'
     OR v_rows->2->'x'->>'settlement_ref' IS DISTINCT FROM 'batch'
     OR v_rows->3->'x'->>'settlement_ref' IS DISTINCT FROM 'db'
     OR v_rows->0->'x' ? 'settlement_ref' THEN
    RAISE EXCEPTION 'FAIL [settlement_ref]: % / % / % / %', v_rows->0->'x', v_rows->1->'x', v_rows->2->'x', v_rows->3->'x';
  END IF;
  -- neues Depot im Import, Verrechnungskonto aus dem Bestand (der gemeldete Fall)
  v_res := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__test_icr Neu-Depot','account_type','stocks_depot',
                       'settlement_account','__test_icr Alt-Giro'),
    jsonb_build_object('entity_type','stock_buy','depot','__test_icr Neu-Depot','isin','IE00BK5BQT80',
                       'shares',2,'price_per_share',100))));
  IF (v_res->>'valid')::int IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL [fixture 2]: %', v_res; END IF;
  v_rows := finance.fn_import_card_rows((v_res->>'batch_id')::uuid);
  IF v_rows->0->'x'->>'settlement_ref' IS DISTINCT FROM 'db'
     OR v_rows->1->'x'->>'settlement' IS DISTINCT FROM '__test_icr Alt-Giro'
     OR v_rows->1->'x'->>'settlement_ref' IS DISTINCT FROM 'db' THEN
    RAISE EXCEPTION 'FAIL [settlement_ref neues Depot + Bestandskonto]: %', v_rows;
  END IF;
  v_rows := finance.fn_import_card_rows(v_batch);
  RAISE NOTICE 'PASS fn_import_card_rows [settlement_ref: batch = wird mit angelegt, db = besteht schon]';

  -- Versicherung: Rate je Abbuchung aus fn_insurance_period_amount, Versicherungsnehmer
  v_r := v_rows->4;
  IF (v_r->'x'->>'period_amount')::numeric IS DISTINCT FROM finance.fn_insurance_period_amount(120, 1, 'month')
     OR v_r->'x'->>'person' IS DISTINCT FROM 'Icra Kartentest' OR v_r->'x'->>'ccy' IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [insurance]: %', v_r;
  END IF;
  -- Sparziel: Plan aus fn_savings_goal_funding (dieselbe Ableitung wie fn_create_savings_goal; ohne Sparplan und
  -- Dauerauftrag = fn_savings_rate_schedule); keine Person genannt -> Inhaber des (batch-internen) Spartopfs,
  -- wie fn_create_savings_goal beim Write (fn_default_beneficiary)
  v_r := v_rows->5;
  IF (v_r->'x'->'schedule'->>'ok')::boolean IS DISTINCT FROM true
     OR v_r->'x'->'schedule'->'monthly_rate' IS DISTINCT FROM finance.fn_savings_rate_schedule(v_r->'p')->'monthly_rate'
     OR v_r->'x'->'schedule'->'target_date' IS DISTINCT FROM finance.fn_savings_rate_schedule(v_r->'p')->'target_date'
     OR v_r->'x'->'schedule'->'first_payment_date' IS DISTINCT FROM finance.fn_savings_rate_schedule(v_r->'p')->'first_payment_date'
     OR v_r->'x'->>'person' IS DISTINCT FROM 'Icra Kartentest' THEN
    RAISE EXCEPTION 'FAIL [savings_goal]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_import_card_rows [insurance Rate + savings_goal Plan aus denselben fn wie der Write]';

  -- Standmitteilung: Name = referenzierte Rente
  v_r := v_rows->7;
  IF v_r->>'name' IS DISTINCT FROM '__test_icr Rente' THEN
    RAISE EXCEPTION 'FAIL [pension_statement]: %', v_r;
  END IF;
  -- Dauerauftrag: Waehrung des Kontos
  v_r := v_rows->8;
  IF v_r->'x'->>'ccy' IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [recurring_payment]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_import_card_rows [pension_statement nominal-Default, recurring Waehrung]';

  -- Kredit (laufend): Aufteilung der 1. Rate aus der Restschuld wie fn_create_loan (60.000 * 2 % / 12 = 100,00 Zins)
  v_res := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','loan','name','__test_icr Kredit','current_balance',60000,'interest_rate',2,
                       'monthly_annuity',400,'first_payment_date','2026-11-30','debit_account','__test_icr Alt-Giro'))));
  IF (v_res->>'valid')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [fixture loan]: %', v_res; END IF;
  v_r := finance.fn_import_card_rows((v_res->>'batch_id')::uuid)->0;
  IF (v_r->'x'->'rate_split'->>'interest')::numeric IS DISTINCT FROM 100.00
     OR (v_r->'x'->'rate_split'->>'principal')::numeric IS DISTINCT FROM 300.00
     OR (v_r->'x'->>'running')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [loan rate_split]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_import_card_rows [loan: Aufteilung 1. Rate 100/300 aus der Restschuld]';

  -- Unbekannter/leerer Batch -> leeres Array (nie NULL, nie 0 Items)
  IF finance.fn_import_card_rows(gen_random_uuid()) IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [leer]: %', finance.fn_import_card_rows(gen_random_uuid());
  END IF;
  RAISE NOTICE 'PASS fn_import_card_rows [leerer Batch -> []]';
END;
$$;

ROLLBACK;
