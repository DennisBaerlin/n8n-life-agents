-- tests/db/finance/test_fn_create_recurring_payment.sql
-- Testet fn_create_recurring_payment: Vorzeichen aus direction, monthly_equivalent, Guards.
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_acct_id INT;
  v_rp_id   INT;
  v_amount  NUMERIC;
BEGIN

  SELECT finance.fn_create_account(
    '{"name":"__test_recpay_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;

  -- TEST 1: Einnahme (income) -> +amount, monthly_equivalent
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Gehalt','account_id',v_acct_id,'direction','income','amount',3000,
    'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2026-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [income]: erwartet ok=true, got %', v_result;
  END IF;
  IF (v_result->>'monthly_equivalent')::numeric IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [income me]: erwartet 3000, got %', v_result;
  END IF;
  v_rp_id := (v_result->>'recurring_payment_id')::int;
  SELECT amount INTO v_amount FROM finance.recurring_payments WHERE id = v_rp_id;
  IF v_amount IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [income sign]: erwartet +3000, got %', v_amount;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [income +3000]';

  -- TEST 2: Ausgabe (expense) -> -amount
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Miete','account_id',v_acct_id,'direction','expense','amount',1500,
    'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2026-01-01'
  )) INTO v_result;
  v_rp_id := (v_result->>'recurring_payment_id')::int;
  SELECT amount INTO v_amount FROM finance.recurring_payments WHERE id = v_rp_id;
  IF v_amount IS DISTINCT FROM -1500 THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [expense sign]: erwartet -1500, got %', v_amount;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [expense -1500]';

  -- TEST 3: amount <= 0 -> {ok:false}
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Null','account_id',v_acct_id,'direction','income','amount',0,
    'schedule_unit','month','first_payment_date','2026-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [amount<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [amount<=0 -> ok:false]';

  -- TEST 4: ungueltige direction -> {ok:false}
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Quatsch','account_id',v_acct_id,'direction','sideways','amount',100,
    'schedule_unit','month','first_payment_date','2026-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [bad direction]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [bad direction -> ok:false]';

END $$;

-- TEST 5: Cashflow-Sofort-Hinweis (Event-Fold). Die fn liest monthly_cashflow_summary (globale
-- Single-Row-View) -> SAVEPOINT + bestehende rp (Tests 1-4 + evtl. Seed) neutralisieren, kontrollierten Cashflow
-- setzen, danach ROLLBACK TO SAVEPOINT. (5a) Einnahmen-Anlage -> net>0 -> keine Note (Kontrolle). (5b) Ausgabe >
-- Einnahmen -> net<0 -> cashflow_coverage-Note im {ok:true}-Return.
SAVEPOINT crp_fold;
UPDATE finance.recurring_payments SET status = 'paused';   -- nur im Savepoint; FK-frei
DO $$
DECLARE
  v_res jsonb; v_acct int;
BEGIN
  SELECT finance.fn_create_account('{"name":"__crp_fold_acct__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- (5a) Einkommen +2000 (nur diese rp aktiv) -> net +2000 -> keine Note
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__crp_fold_inc__','account_id',v_acct,'direction','income','amount',2000,
    'schedule_unit','month','first_payment_date',current_date::text)) INTO v_res;
  IF v_res ? 'cashflow_coverage' THEN
    RAISE EXCEPTION 'FAIL [5a]: cashflow_coverage-Fold trotz gesundem net (+2000), got %', v_res; END IF;
  RAISE NOTICE 'PASS [5a: Einnahme -> net>0 -> kein Fold]';

  -- (5b) Ausgabe -3000 -> net = 2000 - 3000 = -1000 -> cashflow_coverage-Note
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__crp_fold_exp__','account_id',v_acct,'direction','expense','amount',3000,
    'schedule_unit','month','first_payment_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [5b setup]: %', v_res; END IF;
  IF NOT (v_res ? 'cashflow_coverage') OR COALESCE(v_res->'cashflow_coverage'->>'note','') = '' THEN
    RAISE EXCEPTION 'FAIL [5b]: kein cashflow_coverage-Fold mit note bei net<0, got %', v_res; END IF;
  RAISE NOTICE 'PASS [5b: Ausgabe kippt net<0 -> cashflow_coverage-Fold im Return]';
END $$;
ROLLBACK TO SAVEPOINT crp_fold;

-- TEST 6: Namenssperre nur in der oeffentlichen create-fn, Praedikat = active_recurring_payments.
--   (a) laufende, freistehende Zahlung gleichen Namens (ohne Gross-/Kleinschreibung) -> ok:false duplicate_name + candidates
--   (b) gleichnamige Zahlung einer Entitaet (Versicherung) blockiert nicht -> ok:true + Hinweis-Zeile auf der Karte
DO $$
DECLARE v_acct int; v_r jsonb;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__test_rpdup_acct__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPDUP Streaming__','account_id',v_acct,
           'direction','expense','amount',10,'schedule_unit','month','first_payment_date','2026-01-05'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6 Setup]: %', v_r; END IF;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__rpdup streaming__','account_id',v_acct,
           'direction','expense','amount',12,'schedule_unit','month','first_payment_date','2026-02-05'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'duplicate_name'
     OR jsonb_array_length(v_r->'candidates') <> 1 THEN
    RAISE EXCEPTION 'FAIL [6a Namens-Dublette laufend]: %', v_r; END IF;

  v_r := finance.fn_create_insurance(jsonb_build_object('name','__RPDUP Hausrat__','annual_premium',120,
           'first_payment_date','2026-01-15','debit_account_id',v_acct));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6 Setup Versicherung]: %', v_r; END IF;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name',
           (SELECT rp.name FROM finance.recurring_payments rp JOIN finance.insurances i ON i.recurring_payment_id = rp.id
             WHERE i.name = '__RPDUP Hausrat__'),
           'account_id',v_acct,'direction','expense','amount',10,'schedule_unit','year','first_payment_date','2026-03-01'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l
                    WHERE l->>'kind' = 'note' AND l->>'value' = 'finance.note.similar_recurring_payment') THEN
    RAISE EXCEPTION 'FAIL [6b Entitaets-Zahlung gleichen Namens -> nur Hinweis]: %', v_r; END IF;
  RAISE NOTICE 'PASS [6 Namenssperre: laufend frei -> ok:false, Entitaets-Zahlung -> Karten-Hinweis]';

  -- (c) noch nicht gestartete Zahlung gleichen Namens sperrt ebenfalls und nennt ihr Startdatum
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPDUP Beitrag__','account_id',v_acct,
           'direction','income','amount',50,'schedule_unit','month','first_payment_date',to_char(CURRENT_DATE + 10, 'YYYY-MM-DD')));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6c Setup]: %', v_r; END IF;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__rpdup beitrag__','account_id',v_acct,
           'direction','income','amount',50,'schedule_unit','month','first_payment_date',to_char(CURRENT_DATE + 12, 'YYYY-MM-DD')));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'duplicate_name'
     OR v_r->'candidates'->0->>'starts_on' IS DISTINCT FROM to_char(CURRENT_DATE + 10, 'YYYY-MM-DD')
     OR position(to_char(CURRENT_DATE + 10, 'YYYY-MM-DD') IN v_r->>'reason') = 0 THEN
    RAISE EXCEPTION 'FAIL [6c noch nicht gestartet]: %', v_r; END IF;
  -- auch spaet startende Zahlungen (ausserhalb der Monatsrechnung) sind erfasst
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPDUP Spaet__','account_id',v_acct,
           'direction','expense','amount',50,'schedule_unit','month','first_payment_date',to_char(CURRENT_DATE + 90, 'YYYY-MM-DD')));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6c Setup spaet]: %', v_r; END IF;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__rpdup spaet__','account_id',v_acct,
           'direction','expense','amount',50,'schedule_unit','month','first_payment_date',to_char(CURRENT_DATE + 2, 'YYYY-MM-DD')));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'duplicate_name' THEN
    RAISE EXCEPTION 'FAIL [6c spaet]: %', v_r; END IF;
  RAISE NOTICE 'PASS [6c Namenssperre: noch nicht gestartet -> ok:false mit Startdatum]';

  -- [7] Spar-Deckung (fn_savings_funding_fold, Bericht): Zuwendung von aussen (Einnahme ohne Quellkonto) auf das Konto
  --     eines Sparplans -> Kartenzeile „gedeckt" + Bericht ohne Frage; eine Zahlung auf ein Konto ohne Sparplan -> nichts
  DECLARE v_s7 INT; BEGIN
    v_s7 := (finance.fn_create_account('{"name":"__test_rpf_settle__","account_type":"cash","opening_balance":100}'::jsonb)->>'account_id')::int;
    PERFORM finance.fn_create_account(jsonb_build_object('name','__test_rpf_depot__','account_type','stocks_depot','settlement_id', v_s7));
    v_r := finance.fn_create_savings_plan(jsonb_build_object('name','__test_rpf_plan__','depot_name','__test_rpf_depot__',
      'isin','IE00B3RBWM25','symbol','VWCE','security_name','Beispiel','amount',200,'schedule_unit','month',
      'first_payment_date', (CURRENT_DATE + 5)::text));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [7 Setup]: %', v_r; END IF;
    v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPF Zuwendung Oma__','account_id',v_s7,
             'direction','income','amount',200,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 1)::text));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l WHERE l->>'value' = 'finance.note.funding_ok')
       OR v_r->'savings_funding'->'accounts'->0->>'state' <> 'ok'
       OR (v_r->'savings_funding'->'accounts'->0->>'monthly_in')::numeric <> 200
       OR (v_r->'savings_funding'->'accounts'->0->>'asked')::boolean
       OR v_r->'savings_funding'->>'note' LIKE '%ASK%' THEN
      RAISE EXCEPTION 'FAIL [7a Zuwendung -> gedeckt]: %', v_r; END IF;
    v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPF Abo__','account_id',v_acct,
             'direction','expense','amount',5,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 1)::text));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r ? 'savings_funding' THEN
      RAISE EXCEPTION 'FAIL [7b Konto ohne Sparplan -> kein Bericht]: %', v_r; END IF;
    -- [7c] Ausgabe (keine Sparrate) auf dem Sparplan-Konto: das Konto wird Ausgabenkonto, ohne Auszug sind seine
    --      Alltagsausgaben unbekannt -> neutral -> weder Kartenzeile noch Bericht (die App zeigt „nicht ermittelbar")
    v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPF Gebuehr__','account_id',v_s7,
             'direction','expense','amount',1,'schedule_unit','year','first_payment_date',(CURRENT_DATE + 30)::text));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r ? 'savings_funding'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l WHERE l->>'value' LIKE 'finance.note.funding_%') THEN
      RAISE EXCEPTION 'FAIL [7c Ausgabe -> neutral, nichts]: %', v_r; END IF;
    RAISE NOTICE 'PASS [7 Spar-Deckung: Zuwendung -> gedeckt; Ausgabe macht das Konto unbestimmbar -> still; anderes Konto -> nichts]';
  END;

  -- TEST 8 ("Import zuerst"): optionale Gegen-IBAN aus dem Vorschlag -> Schluessel fuer den Monats-Check (Stufe A),
  --   sichtbar auf der Karte; keine echte IBAN -> ok:false ohne Write; leer -> ohne Schluessel.
  DECLARE
    v_r  JSONB;
  BEGIN
    v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPI Miete__','account_id',v_acct,
             'direction','expense','amount',850,'schedule_unit','month','schedule_day_of_month',1,
             'first_payment_date',(CURRENT_DATE + 3)::text,'counterparty_iban','de89 3704 0044 0532 0130 00'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true
       OR NOT EXISTS (SELECT 1 FROM finance.recurring_payment_keys k
                      WHERE k.recurring_payment_id = (v_r->>'recurring_payment_id')::int AND k.key_type = 'counterparty_iban'
                        AND k.key_value = 'DE89370400440532013000' AND k.source = 'user')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l
                      WHERE l->>'value' = 'finance.note.recurring_iban_key' AND l->'params'->>'iban' = 'DE89370400440532013000') THEN
      RAISE EXCEPTION 'FAIL [8a IBAN -> Schluessel + Kartenzeile]: %', v_r; END IF;
    v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPI Falsch__','account_id',v_acct,
             'direction','expense','amount',5,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 3)::text,
             'counterparty_iban','DE00370400440532013000'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' IS NULL
       OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__RPI Falsch__') THEN
      RAISE EXCEPTION 'FAIL [8b falsche IBAN -> ok:false ohne Write]: %', v_r; END IF;
    v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPI Leer__','account_id',v_acct,
             'direction','expense','amount',5,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 3)::text,
             'counterparty_iban',''));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true
       OR EXISTS (SELECT 1 FROM finance.recurring_payment_keys k WHERE k.recurring_payment_id = (v_r->>'recurring_payment_id')::int) THEN
      RAISE EXCEPTION 'FAIL [8c leere IBAN -> ohne Schluessel]: %', v_r; END IF;
    RAISE NOTICE 'PASS [8 Gegen-IBAN -> Schluessel + Kartenzeile; falsche IBAN abgelehnt]';
  END;
END $$;

ROLLBACK;

-- ---------- Mandat aus einem Kontoauszugs-Vorschlag -> sepa_mandate-Schluessel ----------
BEGIN;
DO $$
DECLARE v_acct INT; v_r JSONB; v_r2 JSONB;
BEGIN
    v_acct := (finance.fn_create_account(jsonb_build_object('name', '__t_crp_mand__', 'account_type', 'cash', 'currency', 'EUR',
                 'opening_balance', 0, 'opening_balance_date', (core.fn_today() - 30)::text))->>'account_id')::int;
    v_r := finance.fn_create_recurring_payment(jsonb_build_object('name', 'Strom Mandat', 'account_id', v_acct, 'direction', 'expense',
               'amount', 80, 'schedule_unit', 'month', 'schedule_day_of_month', 15, 'first_payment_date', (core.fn_today() + 5)::text,
               'creditor_id', 'de98 zzz0 9999 9999 99', 'mandate_ref', 'm-47 11'));
    IF NOT EXISTS (SELECT 1 FROM finance.recurring_payment_keys WHERE recurring_payment_id = (v_r->>'recurring_payment_id')::int
                   AND key_type = 'sepa_mandate' AND key_value = 'DE98ZZZ09999999999|M-4711') THEN
        RAISE EXCEPTION 'FAIL [sepa_mandate gelernt]: %', v_r;
    END IF;
    -- schon vergeben -> die zweite Zahlung lernt es still nicht (global eindeutig)
    v_r2 := finance.fn_create_recurring_payment(jsonb_build_object('name', 'Strom Zweit', 'account_id', v_acct, 'direction', 'expense',
               'amount', 81, 'schedule_unit', 'month', 'schedule_day_of_month', 16, 'first_payment_date', (core.fn_today() + 5)::text,
               'creditor_id', 'DE98ZZZ09999999999', 'mandate_ref', 'M-4711'));
    IF (v_r2->>'ok')::boolean IS DISTINCT FROM true OR EXISTS (SELECT 1 FROM finance.recurring_payment_keys
                   WHERE recurring_payment_id = (v_r2->>'recurring_payment_id')::int AND key_type = 'sepa_mandate') THEN
        RAISE EXCEPTION 'FAIL [Mandat schon vergeben]: %', v_r2;
    END IF;
    -- nur eines von beiden -> kein Schluessel
    v_r2 := finance.fn_create_recurring_payment(jsonb_build_object('name', 'Strom Halb', 'account_id', v_acct, 'direction', 'expense',
               'amount', 82, 'schedule_unit', 'month', 'schedule_day_of_month', 17, 'first_payment_date', (core.fn_today() + 5)::text,
               'creditor_id', 'DE98ZZZ09999999998'));
    IF EXISTS (SELECT 1 FROM finance.recurring_payment_keys WHERE recurring_payment_id = (v_r2->>'recurring_payment_id')::int) THEN
        RAISE EXCEPTION 'FAIL [halbes Mandat]';
    END IF;
    RAISE NOTICE 'PASS [fn_create_recurring_payment lernt sepa_mandate]';
END $$;
ROLLBACK;
