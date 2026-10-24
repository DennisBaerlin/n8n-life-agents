-- tests/db/finance/test_fn_create_account.sql
-- Testet fn_create_account: Konto anlegen + Trigger-Balance-Init + Depot-Settlement-Check
-- Pattern: BEGIN → DO-Block (RAISE EXCEPTION = FAIL) → ROLLBACK (immer clean)
BEGIN;

DO $$
DECLARE
  v_result     JSONB;
  v_id         INT;
  v_settle_id  INT;
  v_depot_id   INT;
  v_balance    NUMERIC;
  v_curr_count INT;
BEGIN

  -- TEST 1: Cash-Konto anlegen
  SELECT finance.fn_create_account(
    '{"name":"__test_cash__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;

  IF NOT (v_result ? 'account_id') OR (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_create_account [1]: ok=true + account_id erwartet, got %', v_result;
  END IF;
  v_id := (v_result->>'account_id')::int;

  SELECT balance INTO v_balance
  FROM finance.account_balances WHERE account_id = v_id;

  IF v_balance IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_create_account [1]: Balance-Trigger hat nicht 0 geliefert, got %', v_balance;
  END IF;

  RAISE NOTICE 'PASS fn_create_account [1 Cash]: account_id=%, balance=%', v_id, v_balance;

  -- TEST 2: Settlement-Konto + Depot anlegen (Depot braucht settlement_account_id)
  SELECT finance.fn_create_account(
    '{"name":"__test_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    jsonb_build_object(
      'name',           '__test_depot__',
      'account_type',   'stocks_depot',
      'account_holder', 'Test',
      'currency',       'EUR',
      'settlement_id',  v_settle_id
    )
  ) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Depot muss settlement_account_id gesetzt haben (DB-CHECK backstop)
  IF NOT EXISTS (
    SELECT 1 FROM finance.accounts
    WHERE id = v_depot_id AND settlement_account_id = v_settle_id
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_account [2]: Depot hat settlement_account_id nicht gesetzt';
  END IF;

  RAISE NOTICE 'PASS fn_create_account [2 Depot]: depot_id=%, settlement_id=%', v_depot_id, v_settle_id;

  -- TEST 3: Konto mit Zinszeile
  SELECT finance.fn_create_account(
    '{"name":"__test_festgeld__","account_type":"fixed_deposit","fixed_deposit_maturity_date":"2030-12-31","account_holder":"Test","currency":"EUR","interest_rate":"3.5","interest_credit_unit":"year"}'::jsonb
  ) INTO v_result;

  IF NOT (v_result->>'interest_added' = 'true') THEN
    RAISE EXCEPTION 'FAIL fn_create_account [3]: interest_added sollte true sein, got %', v_result;
  END IF;
  v_id := (v_result->>'account_id')::int;

  -- fixed_deposit -> day_count-Default 30E/360 (vorgeschlagen aus Kontotyp); jaehrlich -> auto_post false
  IF NOT EXISTS (
    SELECT 1 FROM finance.account_interest_rates
    WHERE account_id = v_id AND annual_rate = 3.5
      AND day_count_convention = '30E/360' AND auto_post = false
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_account [3]: Zinszeile/Defaults (30E/360, auto_post false) nicht korrekt';
  END IF;

  RAISE NOTICE 'PASS fn_create_account [3 Zins fixed_deposit -> 30E/360, auto_post false]';

  -- TEST 3b: cash mit Zins -> day_count-Default ACT/365 (Tagesgeld); taeglich -> auto_post true; interval durchgereicht
  SELECT finance.fn_create_account(jsonb_build_object(
    'name','__test_cash_int__','account_type','cash','currency','EUR','interest_rate',2,
    'interest_credit_unit','day','interest_credit_interval',1
  )) INTO v_result;
  v_id := (v_result->>'account_id')::int;
  IF NOT EXISTS (
    SELECT 1 FROM finance.account_interest_rates
    WHERE account_id = v_id AND day_count_convention = 'ACT/365' AND auto_post = true
      AND schedule_day_of_month IS NULL AND schedule_interval = 1
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_account [3b]: cash-Zins-Defaults/Felder (ACT/365, auto_post true, daily ohne Tag) nicht korrekt';
  END IF;
  -- monatlich zum Monatsende + Arrears am 5. des Folgemonats: dom/posting durchgereicht
  SELECT finance.fn_create_account(jsonb_build_object(
    'name','__test_cash_int_m__','account_type','cash','currency','EUR','interest_rate',2,
    'interest_credit_unit','month','interest_credit_day_of_month',-1,'interest_posting_day_of_month',5
  )) INTO v_result;
  IF NOT EXISTS (
    SELECT 1 FROM finance.account_interest_rates
    WHERE account_id = (v_result->>'account_id')::int AND schedule_day_of_month = -1 AND posting_day_of_month = 5
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_account [3b monthly]: dom -1 / posting 5 nicht durchgereicht: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_account [3b cash-Zins -> ACT/365, auto_post true (daily), dom/posting durchgereicht]';

  -- TEST 3c: Methoden-Override schlaegt den Kontotyp-Default (cash + 30E/360-Override)
  SELECT finance.fn_create_account(jsonb_build_object(
    'name','__test_cash_ovr__','account_type','cash','interest_rate',2,'interest_credit_unit','month',
    'interest_credit_day_of_month',-1,'interest_day_count_convention','30E/360','interest_auto_post',true
  )) INTO v_result;
  IF NOT EXISTS (
    SELECT 1 FROM finance.account_interest_rates
    WHERE account_id = (v_result->>'account_id')::int AND day_count_convention = '30E/360' AND auto_post = true
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_account [3c]: Override (30E/360, auto_post true) nicht uebernommen';
  END IF;
  RAISE NOTICE 'PASS fn_create_account [3c Methoden-/auto_post-Override schlaegt Default]';

  -- TEST 4 (WP-1 Crash-Schutz): Fremdwaehrung in KLEINSCHREIBUNG ('usd') -> Roh-Input wird normalisiert
  -- ('USD'), registriert, Konto currency='USD'. VOR dem Fix war das der Crash-Pfad: fn_ensure_currency('usd')
  -- gab {ok:false} (verworfen via PERFORM) -> INSERT currency='usd' -> FK-RAISE + Owner-Alert.
  DECLARE v_acc_ccy TEXT; BEGIN
    DELETE FROM finance.currencies WHERE code = 'USD';
    SELECT finance.fn_create_account(
      '{"name":"__test_usd_acct__","account_type":"cash","account_holder":"Test","currency":"usd"}'::jsonb
    ) INTO v_result;
    IF NOT (v_result ? 'account_id') THEN
      RAISE EXCEPTION 'FAIL fn_create_account [4 usd]: kein account_id (normalisiert die fn ''usd''->''USD''?), got %', v_result;
    END IF;
    SELECT count(*) INTO v_curr_count FROM finance.currencies WHERE code = 'USD';
    IF v_curr_count IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'FAIL fn_create_account [4 usd]: fn_ensure_currency hat USD nicht registriert (Normalisierung fehlt?)';
    END IF;
    SELECT currency INTO v_acc_ccy FROM finance.accounts WHERE id = (v_result->>'account_id')::int;
    IF v_acc_ccy IS DISTINCT FROM 'USD' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [4 usd]: Konto-currency erwartet normalisiert ''USD'', got %', v_acc_ccy;
    END IF;
    RAISE NOTICE 'PASS fn_create_account [4 lowercase usd -> normalisiert USD, registriert, kein Crash]';
  END;

  -- TEST 4b (WP-1): echt-ungueltiger Code ('DOLLAR') -> {ok:false} (kein Konto, kein FK-RAISE/Owner-Alert).
  DECLARE v_cnt_before INT; v_cnt_after INT; BEGIN
    SELECT count(*) INTO v_cnt_before FROM finance.accounts WHERE name = '__test_bad_ccy_acct__';
    SELECT finance.fn_create_account(
      '{"name":"__test_bad_ccy_acct__","account_type":"cash","currency":"DOLLAR"}'::jsonb
    ) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL fn_create_account [4b DOLLAR]: erwartet ok=false, got %', v_result;
    END IF;
    SELECT count(*) INTO v_cnt_after FROM finance.accounts WHERE name = '__test_bad_ccy_acct__';
    IF v_cnt_after IS DISTINCT FROM v_cnt_before THEN
      RAISE EXCEPTION 'FAIL fn_create_account [4b DOLLAR]: Konto trotz ok=false angelegt';
    END IF;
    RAISE NOTICE 'PASS fn_create_account [4b ungueltiger Code DOLLAR -> ok:false, kein Write]';
  END;

  -- TEST 5 (WS-4): owner_person_id ist das EINZIGE Inhaber-Feld (account_holder abgeloest).
  -- Fixture: eine projizierte Person (FK-Ziel). Kind-Custodial-Depot-Szenario.
  INSERT INTO agent.persons (person_id, full_name, role)
  VALUES ('__test_acc_kid', 'Test Kind', 'child') ON CONFLICT (person_id) DO NOTHING;

  SELECT finance.fn_create_account(
    jsonb_build_object('name','__test_kid_acct__','account_type','cash','currency','EUR',
                       'owner_person_id','__test_acc_kid')
  ) INTO v_result;
  v_id := (v_result->>'account_id')::int;
  IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_id AND owner_person_id = '__test_acc_kid') THEN
    RAISE EXCEPTION 'FAIL fn_create_account [5]: owner_person_id nicht gesetzt (id=%)', v_id;
  END IF;
  -- Konto OHNE owner_person_id -> NULL = Haushalt (TEST 1 oben).
  SELECT account_id::int INTO v_id FROM (SELECT (finance.fn_create_account(
    '{"name":"__test_hh_acct__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id') AS account_id) s;
  IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_id AND owner_person_id IS NULL) THEN
    RAISE EXCEPTION 'FAIL fn_create_account [5b]: ohne owner_person_id muss NULL (Haushalt) sein (id=%)', v_id;
  END IF;
  RAISE NOTICE 'PASS fn_create_account [5 owner_person_id Slug gesetzt + NULL=Haushalt]';

  -- TEST 6 (Eindeutigkeit 2026-10-21): Konto + Eroeffnungssaldo in EINEM Schritt, Post-State balance.
  SELECT finance.fn_create_account(jsonb_build_object(
    'name','__test_open_acct__','account_type','cash','currency','EUR','opening_balance','1142.00',
    'owner_person_id','__test_acc_kid')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'balance')::numeric IS DISTINCT FROM 1142.00 THEN
    RAISE EXCEPTION 'FAIL fn_create_account [6]: erwartet ok=true, balance=1142, got %', v_result;
  END IF;
  v_id := (v_result->>'account_id')::int;
  IF (SELECT count(*) FROM finance.transactions WHERE account_id = v_id AND category = 'other'
        AND amount = 1142.00 AND transaction_date = CURRENT_DATE AND description = 'Eröffnungssaldo') <> 1 THEN
    RAISE EXCEPTION 'FAIL fn_create_account [6]: genau eine Eroeffnungsbuchung other/1142/heute erwartet';
  END IF;
  IF (SELECT last_reconciled_at FROM finance.accounts WHERE id = v_id) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_account [6]: last_reconciled_at gesetzt (verfaelscht den ersten Abgleich-Reminder)';
  END IF;
  RAISE NOTICE 'PASS fn_create_account [6 Eroeffnungssaldo 1142 atomar, balance im Return, kein Reconcile-Stempel]';

  -- TEST 6b: Saldo 0 -> keine Buchung; ueberzogenes Konto (negativ) erlaubt
  SELECT finance.fn_create_account('{"name":"__test_open_zero__","account_type":"cash","opening_balance":"0"}'::jsonb) INTO v_result;
  IF (v_result->>'balance')::numeric IS DISTINCT FROM 0
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = (v_result->>'account_id')::int) THEN
    RAISE EXCEPTION 'FAIL fn_create_account [6b]: Saldo 0 darf keine Buchung erzeugen, got %', v_result;
  END IF;
  SELECT finance.fn_create_account('{"name":"__test_open_neg__","account_type":"cash","opening_balance":"-250.50"}'::jsonb) INTO v_result;
  IF (v_result->>'balance')::numeric IS DISTINCT FROM -250.50 THEN
    RAISE EXCEPTION 'FAIL fn_create_account [6b]: ueberzogener Eroeffnungssaldo -250.50 erwartet, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_account [6b Saldo 0 ohne Buchung, negativer Saldo moeglich]';

  -- TEST 6c: Saldo als deutscher Text (Einzel-Tool) wird erkannt; Unlesbares -> ok:false statt RAISE
  SELECT finance.fn_create_account('{"name":"__test_open_de__","account_type":"cash","opening_balance":"1.234,56"}'::jsonb) INTO v_result;
  IF (v_result->>'balance')::numeric IS DISTINCT FROM 1234.56 THEN
    RAISE EXCEPTION 'FAIL fn_create_account [6c]: "1.234,56" muss 1234.56 ergeben, got %', v_result;
  END IF;
  SELECT finance.fn_create_account('{"name":"__test_open_bad__","account_type":"cash","opening_balance":"viel"}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__test_open_bad__') THEN
    RAISE EXCEPTION 'FAIL fn_create_account [6c]: unlesbarer Saldo muss ok=false ohne Write liefern, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_account [6c deutscher Saldo-Text erkannt, unlesbar -> ok:false]';

  -- TEST 7: Depot mit Eroeffnungssaldo -> ok:false ohne Write
  SELECT finance.fn_create_account(jsonb_build_object('name','__test_open_depot__','account_type','stocks_depot',
    'settlement_id', v_settle_id, 'opening_balance', 500)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__test_open_depot__') THEN
    RAISE EXCEPTION 'FAIL fn_create_account [7]: Depot mit Saldo muss ok=false ohne Write liefern, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_account [7 Depot mit Saldo -> ok:false]';

  -- TEST 8: account_type loan -> ok:false (Kredite nur ueber fn_create_loan)
  SELECT finance.fn_create_account('{"name":"__test_plain_loan__","account_type":"loan"}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__test_plain_loan__') THEN
    RAISE EXCEPTION 'FAIL fn_create_account [8]: loan muss ok=false ohne Write liefern, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_account [8 account_type loan -> ok:false]';

  -- TEST 9 (DB-ist-das-Gesetz S4): Festgeld braucht Zinssatz UND Faelligkeit (vorher nur im Prompt)
  DECLARE v_fd jsonb; BEGIN
    v_fd := finance.fn_create_account('{"name":"__test_fd_norate__","account_type":"fixed_deposit","fixed_deposit_maturity_date":"2027-06-30"}'::jsonb);
    IF (v_fd->>'ok')::boolean IS DISTINCT FROM false OR v_fd->>'reason' NOT LIKE '%interest_rate%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9 Festgeld ohne Zins]: %', v_fd; END IF;
    v_fd := finance.fn_create_account('{"name":"__test_fd_nodate__","account_type":"fixed_deposit","interest_rate":"3.0"}'::jsonb);
    IF (v_fd->>'ok')::boolean IS DISTINCT FROM false OR v_fd->>'reason' NOT LIKE '%fixed_deposit_maturity_date%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9 Festgeld ohne Faelligkeit]: %', v_fd; END IF;
    v_fd := finance.fn_create_account('{"name":"__test_fd_ok__","account_type":"fixed_deposit","interest_rate":"3.0","interest_credit_unit":"year","fixed_deposit_maturity_date":"2027-06-30"}'::jsonb);
    IF (v_fd->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9 Festgeld vollstaendig]: %', v_fd; END IF;
  END;
  RAISE NOTICE 'PASS fn_create_account [9 Festgeld: Zins + Faelligkeit Pflicht]';

  -- TEST 9b (Live-Befund 2026-10-24): kein still erfundener Zins-Rhythmus. Satz ohne Rhythmus, monatlich ohne Tag,
  -- jaehrlich mit festem Tag, taeglich mit Tag, Monatsende mit nicht-kalendertauglichem Intervall -> ok:false OHNE Konto.
  DECLARE v_t jsonb; BEGIN
    v_t := finance.fn_create_account('{"name":"__test_int_nounit__","account_type":"cash","interest_rate":"2.5"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM false OR v_t->>'reason' NOT LIKE '%interest_credit_unit%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b Satz ohne Rhythmus]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_fd_nounit__","account_type":"fixed_deposit","interest_rate":"3.0","fixed_deposit_maturity_date":"2027-06-30"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM false OR v_t->>'reason' NOT LIKE '%interest_credit_unit%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b Festgeld ohne Rhythmus]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_int_m_nodom__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"month"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM false OR v_t->>'reason' NOT LIKE '%interest_credit_day_of_month%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b monatlich ohne Tag]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_int_y_dom__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"year","interest_credit_day_of_month":"15"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM false OR v_t->>'reason' NOT LIKE '%interest_credit_day_of_month%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b jaehrlich mit festem Tag]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_int_d_dom__","account_type":"p2p","interest_rate":"5","interest_credit_unit":"day","interest_credit_day_of_month":"-1"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM false OR v_t->>'reason' NOT LIKE '%interest_credit_day_of_month%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b taeglich mit Tag]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_int_m5__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"month","interest_credit_interval":"5","interest_credit_day_of_month":"-1"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM false OR v_t->>'reason' NOT LIKE '%interest_credit_interval%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b Monatsende alle 5 Monate]: %', v_t; END IF;
    IF EXISTS (SELECT 1 FROM finance.accounts WHERE name IN ('__test_int_nounit__', '__test_fd_nounit__',
                 '__test_int_m_nodom__', '__test_int_y_dom__', '__test_int_d_dom__', '__test_int_m5__')) THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b Ablehnung schrieb trotzdem ein Konto]'; END IF;
    -- gueltig: vierteljaehrlich zum Quartalsende, jaehrlich zum Jahresende, jaehrlich am Jahrestag
    v_t := finance.fn_create_account('{"name":"__test_int_q__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"month","interest_credit_interval":"3","interest_credit_day_of_month":"-1"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL fn_create_account [9b Quartalsende]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_int_ye__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"year","interest_credit_day_of_month":"-1"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL fn_create_account [9b Jahresende]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_int_ya__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"year"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL fn_create_account [9b Jahrestag]: %', v_t; END IF;
    -- Pruefung = Write (Review 2026-10-24): "+3" ist 3 (vierteljaehrlich gespeichert), "3.0"/"last" werden abgelehnt
    v_t := finance.fn_create_account('{"name":"__test_int_plus__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"month","interest_credit_interval":"+3","interest_credit_day_of_month":"-1"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT schedule_interval FROM finance.account_interest_rates WHERE account_id = (v_t->>'account_id')::int) IS DISTINCT FROM 3 THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b +3 = vierteljaehrlich]: %', v_t; END IF;
    v_t := finance.fn_create_account('{"name":"__test_int_badnum__","account_type":"cash","interest_rate":"2.5","interest_credit_unit":"month","interest_credit_interval":"3.0","interest_credit_day_of_month":"last"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM false OR v_t->>'reason' NOT LIKE '%interest_credit_interval, interest_credit_day_of_month%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [9b unlesbare Zahl]: %', v_t; END IF;
    -- ohne Zinssatz braucht es keinen Rhythmus (Girokonto ohne Zinsen)
    v_t := finance.fn_create_account('{"name":"__test_int_none__","account_type":"cash"}'::jsonb);
    IF (v_t->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL fn_create_account [9b ohne Zins]: %', v_t; END IF;
  END;
  RAISE NOTICE 'PASS fn_create_account [9b Zins-Rhythmus Pflicht, Tag passend zum Rhythmus]';

  -- TEST 10 (S6): Kontoname unter aktiven Konten eindeutig, ohne Gross-/Kleinschreibung und typuebergreifend
  -- (wie die Import-Pruefung; Referenzen loesen nur ueber den Namen auf). candidates = das bestehende Konto.
  DECLARE v_dup jsonb; BEGIN
    PERFORM finance.fn_create_account('{"name":"__test_dup Cash__","account_type":"cash"}'::jsonb);
    v_dup := finance.fn_create_account('{"name":"__TEST_DUP CASH__","account_type":"p2p"}'::jsonb);
    IF (v_dup->>'ok')::boolean IS DISTINCT FROM false OR v_dup->>'code' IS DISTINCT FROM 'duplicate_name'
       OR jsonb_array_length(v_dup->'candidates') <> 1 THEN
      RAISE EXCEPTION 'FAIL fn_create_account [10 Namens-Dublette ci/typuebergreifend]: %', v_dup; END IF;
  END;
  RAISE NOTICE 'PASS fn_create_account [10 Namens-Dublette -> ok:false duplicate_name + candidates]';

  -- TEST 11 (Owner-Befund 2026-10-23, neues Konto per Kontoauszug): opening_balance_date = Stichtag des gedruckten
  -- Endsaldos. Eroeffnungsbuchung + accounts.opening_balance_date auf diesen Tag; ohne Datum bleibt es heute.
  DECLARE v_r jsonb; v_d date := core.fn_today() - 1; v_acc int; v_tx_date date; v_tx_amt numeric; BEGIN
    v_r := finance.fn_create_account(jsonb_build_object('name', '__test_obd_ok__', 'account_type', 'cash',
               'opening_balance', '150', 'opening_balance_date', to_char(v_d, 'YYYY-MM-DD')));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'balance')::numeric IS DISTINCT FROM 150
       OR (v_r->>'opening_balance_date')::date IS DISTINCT FROM v_d THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11a Saldo + Stichtag]: %', v_r; END IF;
    v_acc := (v_r->>'account_id')::int;
    SELECT transaction_date, amount INTO v_tx_date, v_tx_amt FROM finance.transactions WHERE account_id = v_acc;
    IF v_tx_date IS DISTINCT FROM v_d OR v_tx_amt IS DISTINCT FROM 150
       OR (SELECT opening_balance_date FROM finance.accounts WHERE id = v_acc) IS DISTINCT FROM v_d THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11a Buchung/Stichtag]: tx % %, account %', v_tx_date, v_tx_amt,
        (SELECT opening_balance_date FROM finance.accounts WHERE id = v_acc); END IF;

    -- (e) ohne Datum: Stand heute (Bestandsverhalten), Rueckgabe traegt das Datum
    v_r := finance.fn_create_account('{"name":"__test_obd_today__","account_type":"cash","opening_balance":"20"}'::jsonb);
    IF (v_r->>'opening_balance_date')::date IS DISTINCT FROM core.fn_today()
       OR (SELECT transaction_date FROM finance.transactions WHERE account_id = (v_r->>'account_id')::int) IS DISTINCT FROM core.fn_today() THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11e ohne Datum = heute]: %', v_r; END IF;

    -- (f) Saldo 0 + Datum: ok, keine Buchung, Stichtag gesetzt
    v_r := finance.fn_create_account(jsonb_build_object('name', '__test_obd_zero__', 'account_type', 'cash',
               'opening_balance', '0', 'opening_balance_date', to_char(v_d, 'YYYY-MM-DD')));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true
       OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = (v_r->>'account_id')::int)
       OR (SELECT opening_balance_date FROM finance.accounts WHERE id = (v_r->>'account_id')::int) IS DISTINCT FROM v_d THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11f Saldo 0 + Datum]: %', v_r; END IF;

    -- (b) Zukunft, (c) ohne Saldo, (d) kein ISO-Datum, (g) Depot -> korrigierbar, kein Konto
    v_r := finance.fn_create_account(jsonb_build_object('name', '__test_obd_future__', 'account_type', 'cash',
               'opening_balance', '10', 'opening_balance_date', to_char(core.fn_today() + 1, 'YYYY-MM-DD')));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%future%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11b Datum in der Zukunft]: %', v_r; END IF;
    v_r := finance.fn_create_account(jsonb_build_object('name', '__test_obd_nobal__', 'account_type', 'cash',
               'opening_balance_date', to_char(v_d, 'YYYY-MM-DD')));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%opening_balance%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11c Datum ohne Saldo]: %', v_r; END IF;
    v_r := finance.fn_create_account('{"name":"__test_obd_de__","account_type":"cash","opening_balance":"10","opening_balance_date":"01.10.2026"}'::jsonb);
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%YYYY-MM-DD%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11d kein ISO-Datum]: %', v_r; END IF;
    v_r := finance.fn_create_account(jsonb_build_object('name', '__test_obd_depot__', 'account_type', 'stocks_depot',
               'settlement_id', v_settle_id, 'opening_balance', '0', 'opening_balance_date', to_char(v_d, 'YYYY-MM-DD')));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11g Depot + Datum]: %', v_r; END IF;
    -- Depot + Datum OHNE Saldo: Depot-Grund (nicht "Saldo fehlt" - das schickte den Agenten zum naechsten Fehler)
    v_r := finance.fn_create_account(jsonb_build_object('name', '__test_obd_depot2__', 'account_type', 'stocks_depot',
               'settlement_id', v_settle_id, 'opening_balance_date', to_char(v_d, 'YYYY-MM-DD')));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%depot%' THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11g Depot + Datum ohne Saldo]: %', v_r; END IF;
    IF EXISTS (SELECT 1 FROM finance.accounts WHERE name IN ('__test_obd_future__', '__test_obd_nobal__', '__test_obd_de__', '__test_obd_depot__')) THEN
      RAISE EXCEPTION 'FAIL fn_create_account [11 Ablehnung schrieb trotzdem ein Konto]'; END IF;
  END;
  RAISE NOTICE 'PASS fn_create_account [11 opening_balance_date: Stichtag, heute-Default, 0, Ablehnungen]';

END $$;

ROLLBACK;
