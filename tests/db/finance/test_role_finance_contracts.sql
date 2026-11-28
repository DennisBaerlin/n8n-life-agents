-- tests/db/finance/test_role_finance_contracts.sql
-- Rollen-Perspektive der Vertrags-Werkzeuge (Versicherung, Vorsorge, Immobilie): jede fn laeuft unter finance_rw, die
--   Write-fns zuerst als Probelauf (core.fn_dry_run, zurueckgerollt) und dann echt, die Lese-/Helfer-fns direkt.
--   Fixture (Konten, Personen, Ausgangs-Policen) legt der Superuser an; zwischen SET LOCAL ROLE und RESET ROLE steht nur
--   der Aufruf der fn unter Test. Geprueft wird die Wirkung (Zeilen, Betraege), nicht nur "kein Fehler": ein fehlendes
--   Recht an Tabelle, Sequenz oder Helfer-fn bricht den Block mit permission denied ab.
--   Namen sind je Block getrennt, weil alle Bloecke in einer Transaktion laufen.
BEGIN;

-- fn_create_insurance: Probelauf schreibt nichts, echter Write legt Beitrags-Kette + Police an
-- (120 EUR Jahresbeitrag monatlich = 10 EUR je Abbuchung, Kette mit negativem Betrag).
DO $$
DECLARE
  r      jsonb;
  p      jsonb;
  v_acct int;
  v_id   int;
  v_rp   int;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"Girokonto Erika Vers1","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  p := jsonb_build_object('name', 'Haftpflicht Erika', 'insurance_company', 'Beispiel Versicherung', 'policy_number', 'HP-1',
         'annual_premium', '120', 'schedule_unit', 'month', 'valid_from', core.fn_today()::text,
         'first_payment_date', core.fn_today()::text, 'debit_account_id', v_acct);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_create_insurance(jsonb)'::regprocedure, p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'premium_amount')::numeric IS DISTINCT FROM 10
     OR EXISTS (SELECT 1 FROM finance.insurances WHERE name = 'Haftpflicht Erika') THEN
    RAISE EXCEPTION 'FAIL [fn_create_insurance Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_create_insurance(p);
  RESET ROLE;
  v_id := (r->>'insurance_id')::int;
  v_rp := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_id IS NULL OR v_rp IS NULL
     OR (r->>'premium_amount')::numeric IS DISTINCT FROM 10 OR (r->>'annual_premium')::numeric IS DISTINCT FROM 120
     OR (r->>'monthly_equivalent')::numeric IS DISTINCT FROM 10
     OR NOT EXISTS (SELECT 1 FROM finance.insurances WHERE id = v_id AND name = 'Haftpflicht Erika' AND status = 'active'
                       AND recurring_payment_id = v_rp)
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp AND account_id = v_acct AND amount = -10)
     THEN RAISE EXCEPTION 'FAIL [fn_create_insurance Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_create_insurance unter finance_rw (Probelauf + Write)';
END $$;

-- fn_set_insurance: Probelauf aendert nichts, echter Write splittet die Beitrags-Kette (10 -> 25 ab +30 Tagen,
-- alter Beitrag bleibt Historie); danach Kuendigung (Status cancelled + Vertragsende).
DO $$
DECLARE
  r      jsonb;
  p      jsonb;
  v_acct int;
  v_id   int;
  v_rp   int;
  v_new  int;
  v_to   date := core.fn_today() + 90;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"Girokonto Erika Vers2","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_insurance(jsonb_build_object('name', 'Hausrat Erika', 'annual_premium', '120', 'schedule_unit', 'month',
         'valid_from', core.fn_today()::text, 'first_payment_date', core.fn_today()::text, 'debit_account_id', v_acct));
  v_id := (r->>'insurance_id')::int;
  v_rp := (r->>'recurring_payment_id')::int;
  p := jsonb_build_object('insurance_id', v_id, 'premium_amount', 25, 'schedule_unit', 'month',
         'effective_from', (core.fn_today() + 30)::text);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_insurance(jsonb)'::regprocedure, p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'split')::boolean IS NOT TRUE
     OR (SELECT recurring_payment_id FROM finance.insurances WHERE id = v_id) IS DISTINCT FROM v_rp
     OR (SELECT count(*) FROM finance.recurring_payments WHERE id = v_rp OR predecessor_id = v_rp) <> 1
     THEN RAISE EXCEPTION 'FAIL [fn_set_insurance Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_insurance(p);
  RESET ROLE;
  v_new := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'split')::boolean IS NOT TRUE OR v_new IS NULL OR v_new = v_rp
     OR (r->>'premium_amount')::numeric IS DISTINCT FROM 25 OR (r->>'annual_premium')::numeric IS DISTINCT FROM 300
     OR (SELECT recurring_payment_id FROM finance.insurances WHERE id = v_id) IS DISTINCT FROM v_new
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_new) IS DISTINCT FROM -25
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -10
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM core.fn_today() + 30
     THEN RAISE EXCEPTION 'FAIL [fn_set_insurance Write Beitrag finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_insurance(jsonb_build_object('insurance_id', v_id, 'status', 'cancelled', 'valid_to', v_to::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT status::text FROM finance.insurances WHERE id = v_id) IS DISTINCT FROM 'cancelled'
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_new) IS DISTINCT FROM v_to + 1
     THEN RAISE EXCEPTION 'FAIL [fn_set_insurance Write Kuendigung finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_set_insurance unter finance_rw (Probelauf, Beitrags-Split, Kuendigung)';
END $$;

-- fn_close_insurance: ohne Buchung Hard-DELETE (Police + Kette), mit Buchung Soft-Close (cancelled, Kette beendet).
DO $$
DECLARE
  r      jsonb;
  v_acct int;
  v_a    int;
  v_rp_a int;
  v_b    int;
  v_rp_b int;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"Girokonto Erika Vers3","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_insurance(jsonb_build_object('name', 'Rechtsschutz Erika', 'annual_premium', '600', 'schedule_unit', 'month',
         'valid_from', core.fn_today()::text, 'first_payment_date', core.fn_today()::text, 'debit_account_id', v_acct));
  v_a := (r->>'insurance_id')::int; v_rp_a := (r->>'recurring_payment_id')::int;
  r := finance.fn_create_insurance(jsonb_build_object('name', 'Unfall Max', 'annual_premium', '1200', 'schedule_unit', 'month',
         'valid_from', core.fn_today()::text, 'first_payment_date', core.fn_today()::text, 'debit_account_id', v_acct));
  v_b := (r->>'insurance_id')::int; v_rp_b := (r->>'recurring_payment_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
  VALUES (v_acct, -100, core.fn_today() - 30, 'other', v_rp_b, 'Beitrag Unfall Max');

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_close_insurance(jsonb)'::regprocedure, jsonb_build_object('insurance_name', 'Rechtsschutz Erika'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'deleted'
     OR NOT EXISTS (SELECT 1 FROM finance.insurances WHERE id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_close_insurance Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_insurance(jsonb_build_object('insurance_name', 'Rechtsschutz Erika'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'deleted' OR (r->>'tx_count')::int IS DISTINCT FROM 0
     OR EXISTS (SELECT 1 FROM finance.insurances WHERE id = v_a)
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp_a) THEN
    RAISE EXCEPTION 'FAIL [fn_close_insurance Hard-DELETE finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_insurance(jsonb_build_object('insurance_name', 'Unfall Max'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'closed' OR (r->>'tx_count')::int IS DISTINCT FROM 1
     OR (SELECT status::text FROM finance.insurances WHERE id = v_b) IS DISTINCT FROM 'cancelled'
     OR (SELECT status::text FROM finance.recurring_payments WHERE id = v_rp_b) IS DISTINCT FROM 'paused'
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp_b) IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [fn_close_insurance Soft-Close finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_close_insurance unter finance_rw (Probelauf, Hard-DELETE, Soft-Close)';
END $$;

-- fn_resolve_insurance (Lese-fn): eindeutiger Name -> id + hit_count 1, Kandidaten tragen Name und Status.
DO $$
DECLARE
  r       jsonb;
  v_acct  int;
  v_id    int;
  v_hit   int;
  v_found int;
  v_cand  jsonb;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"Girokonto Erika Vers4","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_insurance(jsonb_build_object('name', 'Kfz Max', 'annual_premium', '360', 'schedule_unit', 'month',
         'valid_from', core.fn_today()::text, 'first_payment_date', core.fn_today()::text, 'debit_account_id', v_acct));
  v_id := (r->>'insurance_id')::int;

  SET LOCAL ROLE finance_rw;
  SELECT x.id, x.hit_count, x.candidates INTO v_found, v_hit, v_cand FROM finance.fn_resolve_insurance('Kfz Max', true) x;
  RESET ROLE;
  IF v_hit IS DISTINCT FROM 1 OR v_found IS DISTINCT FROM v_id OR v_cand->0->>'name' IS DISTINCT FROM 'Kfz Max'
     OR v_cand->0->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_insurance finance_rw]: id=% hit=% cand=%', v_found, v_hit, v_cand; END IF;
  RAISE NOTICE 'PASS fn_resolve_insurance unter finance_rw';
END $$;

-- fn_insurance_fields (Lese-/Pruef-Helfer): deutscher Jahresbeitrag "1.200" monatlich -> 100 je Abbuchung, 1200 im Jahr.
DO $$
DECLARE r jsonb;
BEGIN
  SET LOCAL ROLE finance_rw;
  r := finance.fn_insurance_fields('{"annual_premium":"1.200","schedule_unit":"month","coverage_amount":"50.000"}'::jsonb);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'premium_amount')::numeric IS DISTINCT FROM 100
     OR (r->>'annual_premium')::numeric IS DISTINCT FROM 1200 OR (r->>'coverage_amount')::numeric IS DISTINCT FROM 50000
     OR r->>'schedule_unit' IS DISTINCT FROM 'month' THEN
    RAISE EXCEPTION 'FAIL [fn_insurance_fields finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_insurance_fields unter finance_rw';
END $$;

-- fn_set_pension: Probelauf aendert nichts, echter Write setzt Wert (+ Bewertungsdatum heute) und splittet den Beitrag
-- (150 -> 175 ab +30 Tagen); danach Status paid_out pausiert die Beitrags-Kette.
DO $$
DECLARE
  r      jsonb;
  p      jsonb;
  v_acct int;
  v_id   int;
  v_rp   int;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"Girokonto Erika Rente1","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_pension(jsonb_build_object('name', 'Ruerup Erika', 'pension_type', 'ruerup', 'current_value', 10000,
         'contribution_amount', 150, 'debit_account_id', v_acct, 'first_payment_date', core.fn_today()::text));
  v_id := (r->>'pension_id')::int;
  v_rp := (r->>'recurring_payment_id')::int;
  p := jsonb_build_object('pension_id', v_id, 'current_value', 12500, 'contribution_amount', 175,
         'effective_from', (core.fn_today() + 30)::text);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_pension(jsonb)'::regprocedure, p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT current_value FROM finance.pension WHERE id = v_id) IS DISTINCT FROM 10000
     OR (SELECT recurring_payment_id FROM finance.pension WHERE id = v_id) IS DISTINCT FROM v_rp THEN
    RAISE EXCEPTION 'FAIL [fn_set_pension Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_pension(p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'split')::boolean IS NOT TRUE
     OR (r->>'contribution_amount')::numeric IS DISTINCT FROM 175
     OR (SELECT current_value FROM finance.pension WHERE id = v_id) IS DISTINCT FROM 12500
     OR (SELECT value_updated_at FROM finance.pension WHERE id = v_id) IS DISTINCT FROM core.fn_today()
     OR (SELECT amount FROM finance.recurring_payments WHERE id = (r->>'recurring_payment_id')::int) IS DISTINCT FROM -175
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -150 THEN
    RAISE EXCEPTION 'FAIL [fn_set_pension Write Wert+Beitrag finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_pension(jsonb_build_object('pension_id', v_id, 'status', 'paid_out'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT status::text FROM finance.pension WHERE id = v_id) IS DISTINCT FROM 'paid_out'
     OR EXISTS (SELECT 1 FROM finance.recurring_payments
                 WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp)) AND status <> 'paused') THEN
    RAISE EXCEPTION 'FAIL [fn_set_pension Write Status finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_set_pension unter finance_rw (Probelauf, Wert+Beitrag, paid_out)';
END $$;

-- fn_close_pension: ohne Historie Hard-DELETE (Vorsorge + Kette), mit Buchung Soft-Close (paused, Kette beendet).
DO $$
DECLARE
  r      jsonb;
  v_acct int;
  v_a    int;
  v_rp_a int;
  v_b    int;
  v_rp_b int;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"Girokonto Erika Rente2","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_pension(jsonb_build_object('name', 'Privatrente Erika', 'pension_type', 'private',
         'contribution_amount', 150, 'debit_account_id', v_acct, 'first_payment_date', core.fn_today()::text));
  v_a := (r->>'pension_id')::int; v_rp_a := (r->>'recurring_payment_id')::int;
  r := finance.fn_create_pension(jsonb_build_object('name', 'Riester Max', 'pension_type', 'riester',
         'contribution_amount', 200, 'debit_account_id', v_acct, 'first_payment_date', core.fn_today()::text));
  v_b := (r->>'pension_id')::int; v_rp_b := (r->>'recurring_payment_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
  VALUES (v_acct, -200, core.fn_today() - 30, 'other', v_rp_b, 'Beitrag Riester Max');

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_close_pension(jsonb)'::regprocedure, jsonb_build_object('pension_name', 'Privatrente Erika'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'deleted'
     OR NOT EXISTS (SELECT 1 FROM finance.pension WHERE id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_close_pension Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_pension(jsonb_build_object('pension_name', 'Privatrente Erika'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'deleted'
     OR EXISTS (SELECT 1 FROM finance.pension WHERE id = v_a)
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp_a) THEN
    RAISE EXCEPTION 'FAIL [fn_close_pension Hard-DELETE finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_pension(jsonb_build_object('pension_name', 'Riester Max'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'closed' OR (r->>'tx_count')::int IS DISTINCT FROM 1
     OR (SELECT status::text FROM finance.pension WHERE id = v_b) IS DISTINCT FROM 'paused'
     OR (SELECT status::text FROM finance.recurring_payments WHERE id = v_rp_b) IS DISTINCT FROM 'paused'
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp_b) IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [fn_close_pension Soft-Close finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_close_pension unter finance_rw (Probelauf, Hard-DELETE, Soft-Close)';
END $$;

-- fn_resolve_pension (Lese-fn): eindeutiger Name -> id + hit_count 1, Kandidat traegt Vorsorge-Typ.
DO $$
DECLARE
  r       jsonb;
  v_id    int;
  v_found int;
  v_hit   int;
  v_cand  jsonb;
BEGIN
  r := finance.fn_create_pension('{"name":"Betriebsrente Max","pension_type":"occupational"}'::jsonb);
  v_id := (r->>'pension_id')::int;

  SET LOCAL ROLE finance_rw;
  SELECT x.id, x.hit_count, x.candidates INTO v_found, v_hit, v_cand FROM finance.fn_resolve_pension('Betriebsrente Max', true) x;
  RESET ROLE;
  IF v_hit IS DISTINCT FROM 1 OR v_found IS DISTINCT FROM v_id OR v_cand->0->>'name' IS DISTINCT FROM 'Betriebsrente Max'
     OR v_cand->0->>'pension_type' IS DISTINCT FROM 'occupational' THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_pension finance_rw]: id=% hit=% cand=%', v_found, v_hit, v_cand; END IF;
  RAISE NOTICE 'PASS fn_resolve_pension unter finance_rw';
END $$;

-- fn_create_real_estate: Probelauf schreibt nichts, echter Write liest "350.000" als 350000, stempelt das Bewertungsdatum
-- und traegt den typisierten Eigentuemer ein.
DO $$
DECLARE
  r jsonb;
  p jsonb;
  v_id int;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('erika_immo', 'Erika Muster', 'owner')
  ON CONFLICT (person_id) DO NOTHING;
  p := jsonb_build_object('name', 'Eigentumswohnung Erika', 'current_value', '350.000', 'owner_person_id', 'erika_immo',
         'living_area_m2', 80, 'year_built', 1995);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_create_real_estate(jsonb)'::regprocedure, p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.real_estate WHERE name = 'Eigentumswohnung Erika') THEN
    RAISE EXCEPTION 'FAIL [fn_create_real_estate Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_create_real_estate(p);
  RESET ROLE;
  v_id := (r->>'real_estate_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM finance.real_estate
                     WHERE id = v_id AND current_value = 350000 AND owner_person_id = 'erika_immo' AND status = 'active'
                       AND value_updated_at = core.fn_today() AND living_area_m2 = 80 AND year_built = 1995) THEN
    RAISE EXCEPTION 'FAIL [fn_create_real_estate Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_create_real_estate unter finance_rw (Probelauf + Write)';
END $$;

-- fn_set_real_estate: Probelauf aendert nichts, echter Write bewertet neu (360.000 als Text -> 360000, Datum heute) und
-- setzt Flaeche/Baujahr; status sold ist hier abgelehnt (Verkauf nur ueber fn_sell_real_estate).
DO $$
DECLARE
  r    jsonb;
  p    jsonb;
  v_id int;
BEGIN
  v_id := (finance.fn_create_real_estate('{"name":"Haus Max","current_value":300000,"value_updated_at":"2020-01-01"}'::jsonb)->>'real_estate_id')::int;
  p := jsonb_build_object('real_estate_id', v_id, 'current_value', '360.000', 'living_area_m2', 120, 'year_built', 1980);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_real_estate(jsonb)'::regprocedure, p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT current_value FROM finance.real_estate WHERE id = v_id) IS DISTINCT FROM 300000 THEN
    RAISE EXCEPTION 'FAIL [fn_set_real_estate Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_real_estate(p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM finance.real_estate
                     WHERE id = v_id AND current_value = 360000 AND value_updated_at = core.fn_today()
                       AND living_area_m2 = 120 AND year_built = 1980) THEN
    RAISE EXCEPTION 'FAIL [fn_set_real_estate Write finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_id, 'status', 'sold'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'use_sell_tool'
     OR (SELECT status::text FROM finance.real_estate WHERE id = v_id) IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL [fn_set_real_estate sold-Ablehnung finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_set_real_estate unter finance_rw (Probelauf, Neubewertung, sold abgelehnt)';
END $$;

-- fn_delete_real_estate: Probelauf laesst die Immobilie stehen, echter Write loescht die Fehlanlage.
DO $$
DECLARE
  r    jsonb;
  v_id int;
BEGIN
  v_id := (finance.fn_create_real_estate('{"name":"Fehlanlage Immobilie","current_value":100000}'::jsonb)->>'real_estate_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_delete_real_estate(jsonb)'::regprocedure, jsonb_build_object('real_estate_name', 'Fehlanlage Immobilie'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.real_estate WHERE id = v_id) THEN
    RAISE EXCEPTION 'FAIL [fn_delete_real_estate Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_delete_real_estate(jsonb_build_object('real_estate_name', 'Fehlanlage Immobilie'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'deleted' OR (r->>'real_estate_id')::int IS DISTINCT FROM v_id
     OR EXISTS (SELECT 1 FROM finance.real_estate WHERE id = v_id) THEN
    RAISE EXCEPTION 'FAIL [fn_delete_real_estate Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_delete_real_estate unter finance_rw (Probelauf + Write)';
END $$;

-- fn_resolve_real_estate (Lese-fn): eindeutiger Name -> id + hit_count 1, Kandidat traegt Eigentuemer.
DO $$
DECLARE
  v_id    int;
  v_found int;
  v_hit   int;
  v_cand  jsonb;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('max_immo', 'Max Muster', 'member')
  ON CONFLICT (person_id) DO NOTHING;
  v_id := (finance.fn_create_real_estate('{"name":"Ferienhaus Max","current_value":200000,"owner_person_id":"max_immo"}'::jsonb)->>'real_estate_id')::int;

  SET LOCAL ROLE finance_rw;
  SELECT x.id, x.hit_count, x.candidates INTO v_found, v_hit, v_cand FROM finance.fn_resolve_real_estate('Ferienhaus Max', true) x;
  RESET ROLE;
  IF v_hit IS DISTINCT FROM 1 OR v_found IS DISTINCT FROM v_id OR v_cand->0->>'name' IS DISTINCT FROM 'Ferienhaus Max'
     OR v_cand->0->>'owner_person_id' IS DISTINCT FROM 'max_immo' THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_real_estate finance_rw]: id=% hit=% cand=%', v_found, v_hit, v_cand; END IF;
  RAISE NOTICE 'PASS fn_resolve_real_estate unter finance_rw';
END $$;

-- fn_sell_real_estate: Probelauf bucht nichts, echter Write bucht den Erloes (+320000) aufs Konto, setzt sold und
-- verknuepft die Erloes-Buchung (sale_tx_id).
DO $$
DECLARE
  r      jsonb;
  p      jsonb;
  v_acct int;
  v_id   int;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"Girokonto Erika Immo","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_id := (finance.fn_create_real_estate('{"name":"Apartment Erika","current_value":300000}'::jsonb)->>'real_estate_id')::int;
  p := jsonb_build_object('real_estate_name', 'Apartment Erika', 'proceeds_account_id', v_acct,
         'sale_date', core.fn_today()::text, 'sale_price', '320000');

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_sell_real_estate(jsonb)'::regprocedure, p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status::text FROM finance.real_estate WHERE id = v_id) IS DISTINCT FROM 'active'
     OR finance.fn_get_balance(v_acct) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [fn_sell_real_estate Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_sell_real_estate(p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'real_estate_id')::int IS DISTINCT FROM v_id
     OR (r->>'sale_price')::numeric IS DISTINCT FROM 320000 OR (r->>'linked_loan_count')::int IS DISTINCT FROM 0
     OR finance.fn_get_balance(v_acct) IS DISTINCT FROM 320000
     OR NOT EXISTS (SELECT 1 FROM finance.real_estate
                     WHERE id = v_id AND status = 'sold' AND current_value = 320000
                       AND sale_tx_id = (r->>'proceeds_tx_id')::int)
     OR NOT EXISTS (SELECT 1 FROM finance.transactions
                     WHERE id = (r->>'proceeds_tx_id')::int AND account_id = v_acct AND amount = 320000) THEN
    RAISE EXCEPTION 'FAIL [fn_sell_real_estate Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_sell_real_estate unter finance_rw (Probelauf + Write)';
END $$;

-- fn_enum_reason (Helfer): gueltiges Label -> NULL, unbekanntes -> Grund mit Feldname und Werteliste.
DO $$
DECLARE v_ok text; v_bad text;
BEGIN
  SET LOCAL ROLE finance_rw;
  v_ok := finance.fn_enum_reason('finance.insurance_status'::regtype, 'cancelled', 'status');
  RESET ROLE;
  SET LOCAL ROLE finance_rw;
  v_bad := finance.fn_enum_reason('finance.insurance_status'::regtype, 'gekuendigt', 'status');
  RESET ROLE;
  IF v_ok IS NOT NULL OR v_bad IS NULL OR position('status' IN v_bad) = 0 OR position('gekuendigt' IN v_bad) = 0
     OR position('cancelled' IN v_bad) = 0 THEN
    RAISE EXCEPTION 'FAIL [fn_enum_reason finance_rw]: gueltig=% unbekannt=%', v_ok, v_bad; END IF;
  RAISE NOTICE 'PASS fn_enum_reason unter finance_rw';
END $$;

-- fn_parse_numeric_or_null (Helfer): deutscher Tausenderpunkt -> Zahl, Dezimalkomma -> Dezimalzahl, Unlesbares -> NULL.
DO $$
DECLARE v_thousand numeric; v_decimal numeric; v_junk numeric;
BEGIN
  SET LOCAL ROLE finance_rw;
  v_thousand := finance.fn_parse_numeric_or_null('350.000', true);
  RESET ROLE;
  SET LOCAL ROLE finance_rw;
  v_decimal := finance.fn_parse_numeric_or_null('1.234,50', true);
  RESET ROLE;
  SET LOCAL ROLE finance_rw;
  v_junk := finance.fn_parse_numeric_or_null('viel', true);
  RESET ROLE;
  IF v_thousand IS DISTINCT FROM 350000 OR v_decimal IS DISTINCT FROM 1234.50 OR v_junk IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [fn_parse_numeric_or_null finance_rw]: 350.000=% 1.234,50=% viel=%', v_thousand, v_decimal, v_junk; END IF;
  RAISE NOTICE 'PASS fn_parse_numeric_or_null unter finance_rw';
END $$;

ROLLBACK;
