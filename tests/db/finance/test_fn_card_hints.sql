-- tests/db/finance/test_fn_card_hints.sql
-- Weiche Warnungen als Karten-Hinweis statt Chat-Rueckfrage (Paket DB-ist-das-Gesetz S2/S6). Die Write-fn liefert
-- card_lines [{kind:'note', value:'finance.note.*', params}] im Ergebnis; der Probelauf haengt sie an die Karte.
-- Hohe Schwelle (NN/g: zu viele Warnungen werden ueberlesen):
--   (1) fn_create_account: aehnliches Konto = gleicher Typ + gleiche Bank (ohne Gross-/Kleinschreibung) + gleicher
--       Inhaber, und KEINE zwei verschiedenen bekannten Kontonummern -> finance.note.similar_account {name}.
--       Anderer Typ / beide IBANs bekannt und verschieden -> kein Hinweis.
--   (2) fn_book_transaction: gleiches Konto + gleicher Betrag (mit Vorzeichen) + Datum +-3 Tage
--       -> finance.note.possible_duplicate {date, amount}; anderer Betrag -> kein Hinweis.
--   (3) fn_book_transfer: dieselbe Regel auf dem Abgangskonto.
BEGIN;

DO $$
DECLARE
  v_r jsonb; v_a int; v_b int;
BEGIN
  PERFORM finance.fn_create_account('{"name":"__ch TR Cash__","account_type":"cash","bank":"Trade Republic"}'::jsonb);
  v_r := finance.fn_create_account('{"name":"__ch Zweitkonto__","account_type":"cash","bank":"trade republic"}'::jsonb);
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l
        WHERE l->>'value' = 'finance.note.similar_account' AND l->'params'->>'name' = '__ch TR Cash__') THEN
    RAISE EXCEPTION 'FAIL card_hints [1 aehnliches Konto]: %', v_r; END IF;

  v_r := finance.fn_create_account('{"name":"__ch TR Depot__","account_type":"p2p","bank":"Trade Republic"}'::jsonb);
  IF jsonb_array_length(COALESCE(v_r->'card_lines', '[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 'FAIL card_hints [1 anderer Typ -> kein Hinweis]: %', v_r; END IF;

  PERFORM finance.fn_create_account('{"name":"__ch Bank A__","account_type":"cash","bank":"__ch_bank__","account_number":"DE89370400440532013000"}'::jsonb);
  v_r := finance.fn_create_account('{"name":"__ch Bank B__","account_type":"cash","bank":"__ch_bank__","account_number":"DE02120300000000202051"}'::jsonb);
  IF jsonb_array_length(COALESCE(v_r->'card_lines', '[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 'FAIL card_hints [1 zwei verschiedene IBANs -> kein Hinweis]: %', v_r; END IF;

  v_a := (finance.fn_create_account('{"name":"__ch_giro__","account_type":"cash","opening_balance":500}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__ch_tg__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', 49.99, 'direction', 'outflow',
            'transaction_date', '2026-10-20'));
  v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', 49.99, 'direction', 'outflow',
            'transaction_date', '2026-10-22'));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l
                  WHERE l->>'value' = 'finance.note.possible_duplicate'
                    AND l->'params'->'date'->>'value' = '2026-10-20' AND (l->'params'->'amount'->>'value')::numeric = 49.99) THEN
    RAISE EXCEPTION 'FAIL card_hints [2 moegliche Doppelbuchung]: %', v_r; END IF;
  v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', 12, 'direction', 'outflow',
            'transaction_date', '2026-10-22'));
  IF jsonb_array_length(COALESCE(v_r->'card_lines', '[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 'FAIL card_hints [2 anderer Betrag -> kein Hinweis]: %', v_r; END IF;

  PERFORM finance.fn_book_transfer(jsonb_build_object('from_account_id', v_a, 'to_account_id', v_b, 'amount', 100,
            'transaction_date', '2026-10-01', 'from_account_name', '__ch_giro__', 'to_account_name', '__ch_tg__'));
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id', v_a, 'to_account_id', v_b, 'amount', 100,
            'transaction_date', '2026-10-03', 'from_account_name', '__ch_giro__', 'to_account_name', '__ch_tg__'));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l WHERE l->>'value' = 'finance.note.possible_duplicate') THEN
    RAISE EXCEPTION 'FAIL card_hints [3 Umbuchung doppelt]: %', v_r; END IF;

  RAISE NOTICE 'PASS card_hints [aehnliches Konto, moegliche Doppelbuchung bei Buchung + Umbuchung, hohe Schwelle]';
END $$;

-- (4) Owner-Entscheid 2026-10-23 (Rest): aehnliche Versicherung/Kredit/Immobilie/Sparziel/Sparplan als Karten-Hinweis
--     finance.note.similar_entry {name}; hohe Schwelle je Typ. Gegenprobe: abweichender Wert -> kein Hinweis.
DO $$
DECLARE r jsonb; v_acct int; v_pot int; v_settle int; v_depot int;
  FUNCTION_HINT text := 'finance.note.similar_entry';
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__chx_giro__","account_type":"cash","opening_balance":1000}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__chx_pot__","account_type":"cash"}'::jsonb)->>'account_id')::int;

  -- Versicherung: gleiche Gesellschaft + gleicher Jahresbeitrag
  PERFORM finance.fn_create_insurance(jsonb_build_object('name','__chx Haftpflicht__','insurance_company','HUK','annual_premium',89,
            'first_payment_date','2026-01-15','debit_account_id',v_acct));
  r := finance.fn_create_insurance(jsonb_build_object('name','__chx Haftpflicht 2__','insurance_company','huk','annual_premium',89,
            'first_payment_date','2026-02-15','debit_account_id',v_acct));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = FUNCTION_HINT AND l->'params'->>'name' = '__chx Haftpflicht__') THEN
    RAISE EXCEPTION 'FAIL card_hints [Versicherung aehnlich]: %', r; END IF;
  r := finance.fn_create_insurance(jsonb_build_object('name','__chx Hausrat__','insurance_company','HUK','annual_premium',120,
            'first_payment_date','2026-02-15','debit_account_id',v_acct));
  IF jsonb_array_length(COALESCE(r->'card_lines','[]'::jsonb)) <> 0 THEN RAISE EXCEPTION 'FAIL card_hints [Versicherung anderer Beitrag]: %', r; END IF;

  -- Kredit: gleiche Bank + gleicher Auszahlungsbetrag
  PERFORM finance.fn_create_loan(jsonb_build_object('name','__chx Auto__','lender','VW Bank','original_amount','18000',
            'disbursement_date','2026-01-01','interest_rate','4','debit_account_id',v_acct));
  r := finance.fn_create_loan(jsonb_build_object('name','__chx Auto 2__','lender','vw bank','original_amount','18000',
            'disbursement_date','2026-02-01','interest_rate','4','debit_account_id',v_acct));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = FUNCTION_HINT) THEN
    RAISE EXCEPTION 'FAIL card_hints [Kredit aehnlich]: %', r; END IF;

  -- Immobilie: gleiche Inhaberschaft + gleicher Wert
  PERFORM finance.fn_create_real_estate('{"name":"__chx Wohnung__","current_value":250000}'::jsonb);
  r := finance.fn_create_real_estate('{"name":"__chx ETW__","current_value":250000}'::jsonb);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = FUNCTION_HINT) THEN
    RAISE EXCEPTION 'FAIL card_hints [Immobilie aehnlich]: %', r; END IF;

  -- Sparziel: gleicher Zielbetrag + gleiches Zieldatum
  PERFORM finance.fn_create_savings_goal(jsonb_build_object('name','__chx Urlaub__','target_amount',5000,'target_date','2028-06-30',
            'account_id',v_acct,'reserve_account_id',v_pot,'first_payment_date','2026-11-01'));
  r := finance.fn_create_savings_goal(jsonb_build_object('name','__chx Reise__','target_amount',5000,'target_date','2028-06-30',
            'account_id',v_acct,'reserve_account_id',v_pot,'first_payment_date','2026-11-01'));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = FUNCTION_HINT) THEN
    RAISE EXCEPTION 'FAIL card_hints [Sparziel aehnlich]: %', r; END IF;

  -- Sparplan: dasselbe Wertpapier im selben Depot
  v_settle := (finance.fn_create_account('{"name":"__chx_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__chx Depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name','__chx World__','depot_name','__chx Depot__','isin','IE00B4L5Y983',
            'symbol','IWDA','security_name','MSCI World','amount',100,'first_payment_date','2026-11-01','schedule_day_of_month',1));
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__chx World 2__','depot_name','__chx Depot__','isin','ie00b4l5y983',
            'symbol','IWDA','security_name','MSCI World','amount',50,'first_payment_date','2026-11-15','schedule_day_of_month',15));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = FUNCTION_HINT) THEN
    RAISE EXCEPTION 'FAIL card_hints [Sparplan aehnlich]: %', r; END IF;

  RAISE NOTICE 'PASS card_hints [Versicherung/Kredit/Immobilie/Sparziel/Sparplan aehnlich -> Karten-Hinweis]';
END $$;

ROLLBACK;
