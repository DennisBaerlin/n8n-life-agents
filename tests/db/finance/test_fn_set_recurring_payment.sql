-- tests/db/finance/test_fn_set_recurring_payment.sql
-- Testet fn_set_recurring_payment: Validity-Split (Vorzeichen erhalten), In-Place-Pause,
-- Standalone-Guard (entitaets-besessen -> {ok:false}), Stichtag-Guard
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_acct INT; v_rp INT; v_new INT;
  v_oldto DATE; v_newamt NUMERIC; v_newfrom DATE; v_status TEXT;
  v_ins_rp INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_srp_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- Standalone-Ausgabe 'Miete' (gespeichert -900), valid_from 2026-01-01
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__test_srp_miete__','account_id',v_acct,'direction','expense','amount',900,
    'schedule_unit','month','first_payment_date','2026-01-01')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;

  -- TEST 1: Betrag 900 -> 1000 zum Stichtag 2026-06-01 -> Split (Vorzeichen negativ erhalten)
  SELECT finance.fn_set_recurring_payment(jsonb_build_object(
    'recurring_payment_id', v_rp, 'amount', 1000, 'valid_from', '2026-06-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_recurring_payment [split]: %', v_res; END IF;
  v_new := (v_res->>'recurring_payment_id')::int;
  SELECT valid_to INTO v_oldto FROM finance.recurring_payments WHERE id = v_rp;
  SELECT amount, valid_from INTO v_newamt, v_newfrom FROM finance.recurring_payments WHERE id = v_new;
  IF v_oldto IS DISTINCT FROM DATE '2026-06-01' THEN
    RAISE EXCEPTION 'FAIL set_recurring_payment [alte beendet]: valid_to=% (erwartet 2026-06-01)', v_oldto; END IF;
  IF v_newamt IS DISTINCT FROM -1000 OR v_newfrom IS DISTINCT FROM DATE '2026-06-01' THEN
    RAISE EXCEPTION 'FAIL set_recurring_payment [neue Zeile]: amount=% from=% (erwartet -1000/2026-06-01)', v_newamt, v_newfrom; END IF;
  RAISE NOTICE 'PASS set_recurring_payment [Split: alte beendet, neue -1000 ab 2026-06-01]';

  -- TEST 2: In-Place Pause der neuen Zeile (kein amount)
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_new, 'status', 'paused')) INTO v_res;
  IF (v_res->>'split')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_recurring_payment [in-place]: split sollte false sein, got %', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.recurring_payments WHERE id = v_new;
  IF v_status IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL set_recurring_payment [pause]: status=% (erwartet paused)', v_status; END IF;
  RAISE NOTICE 'PASS set_recurring_payment [In-Place pause]';

  -- TEST 3: Stichtag nicht nach valid_from -> {ok:false}
  SELECT finance.fn_set_recurring_payment(jsonb_build_object(
    'recurring_payment_id', v_new, 'amount', 1100, 'valid_from', '2026-05-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_recurring_payment [stichtag]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_recurring_payment [Stichtag <= valid_from -> ok:false]';

  -- TEST 4: Standalone-Guard -- entitaets-besessene Zeile (Versicherung) -> {ok:false}
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_srp_ins__','annual_premium',120,'schedule_unit','month','valid_from','2026-01-01','first_payment_date','2026-01-01',
    'debit_account_id',v_acct,'recurring_amount',-10,'policyholder','Test')) INTO v_res;
  v_ins_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_ins_rp, 'status', 'paused')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_recurring_payment [standalone-guard]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_recurring_payment [entitaets-besessen -> ok:false]';
END $$;

-- TEST 6-11 (Audit F2): Split ohne Doppel-Faelligkeit, Anker/Ziel/Ende/Status geerbt, Guards, inklusives Ende.
DO $$
DECLARE
  v_res JSONB; v_acct INT; v_kid INT; v_rp INT; v_new INT; c INT; v_txt TEXT;
  v_to DATE; v_status TEXT; v_target INT; v_first DATE;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_srp2_acct__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_srp2_kid__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_kid := (v_res->>'account_id')::int;

  -- TEST 6: Miete -900 ab 2026-01-01, Erhoehung auf 1000 ab 2026-06-01 -> am 06-01 NUR die neue Rate faellig
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_srp2_miete__','account_id',v_acct,
    'direction','expense','amount',900,'schedule_unit','month','first_payment_date','2026-01-01')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',1000,'valid_from','2026-06-01')) INTO v_res;
  v_new := (v_res->>'recurring_payment_id')::int;
  SELECT string_agg(CASE WHEN o.recurring_payment_id = v_rp THEN 'alt' ELSE 'neu' END, ',') INTO v_txt
  FROM finance.fn_recurring_due_open('2026-06-15') o
  WHERE o.recurring_payment_id IN (v_rp, v_new) AND o.due_date = '2026-06-01';
  IF v_txt IS DISTINCT FROM 'neu' THEN
    RAISE EXCEPTION 'FAIL split [Doppel-Faelligkeit 06-01]: erwartet nur neu, got %', v_txt; END IF;
  RAISE NOTICE 'PASS split [am Stichtag nur die neue Rate faellig]';

  -- TEST 7: Gehalt am 28. (dom NULL), Erhoehung ab 2026-06-01 -> Rhythmus bleibt am 28. (Anker geerbt)
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_srp2_gehalt__','account_id',v_acct,
    'direction','income','amount',3000,'schedule_unit','month','first_payment_date','2026-01-28')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',3200,'valid_from','2026-06-01')) INTO v_res;
  v_new := (v_res->>'recurring_payment_id')::int;
  SELECT string_agg(o.due_date::text, ',' ORDER BY o.due_date) INTO v_txt
  FROM finance.fn_recurring_due_open('2026-06-30') o WHERE o.recurring_payment_id = v_new;
  IF v_txt IS DISTINCT FROM '2026-06-28' THEN
    RAISE EXCEPTION 'FAIL split [Anker]: neue Zeile erwartet nur 2026-06-28, got %', v_txt; END IF;
  RAISE NOTICE 'PASS split [Rhythmus-Anker geerbt: weiter am 28.]';

  -- TEST 8: Dauer-Uebertrag -200 -> 250: neue Zeile bleibt Uebertrag (target_account_id geerbt)
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object('name','__test_srp2_transfer__','from_account_id',v_acct,
    'to_account_id',v_kid,'amount',200,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2026-01-01')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',250,'valid_from','2026-06-01')) INTO v_res;
  v_new := (v_res->>'recurring_payment_id')::int;
  SELECT target_account_id, amount::text INTO v_target, v_txt FROM finance.recurring_payments WHERE id = v_new;
  IF v_target IS DISTINCT FROM v_kid OR v_txt IS DISTINCT FROM '-250.00' THEN
    RAISE EXCEPTION 'FAIL split [Transfer]: target=% amount=% (erwartet %/-250.00)', v_target, v_txt, v_kid; END IF;
  RAISE NOTICE 'PASS split [Dauer-Uebertrag bleibt Uebertrag]';

  -- TEST 9: pausierte Zeile mit Ende -> neue Zeile erbt Status + Ende; bereits beendete Zeile -> ok:false
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_srp2_abo__','account_id',v_acct,
    'direction','expense','amount',10,'schedule_unit','month','first_payment_date','2026-01-01')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'status','paused','valid_to','2026-12-31'));
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',12,'valid_from','2026-06-01')) INTO v_res;
  v_new := (v_res->>'recurring_payment_id')::int;
  SELECT status::text, valid_to INTO v_status, v_to FROM finance.recurring_payments WHERE id = v_new;
  IF v_status IS DISTINCT FROM 'paused' OR v_to IS DISTINCT FROM DATE '2027-01-01' THEN
    RAISE EXCEPTION 'FAIL split [Status/Ende geerbt]: status=% valid_to=% (erwartet paused/2027-01-01)', v_status, v_to; END IF;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_new,'amount',15,'valid_from','2027-03-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL split [bereits beendet]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS split [Status + Ende geerbt; Split nach Ende -> ok:false]';

  -- TEST 10: rueckwirkender Stichtag vor einer bereits gebuchten Rate -> ok:false (last_booked)
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_srp2_strom__','account_id',v_acct,
    'direction','expense','amount',80,'schedule_unit','month','first_payment_date','2026-03-01')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date','2026-05-01'));
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',90,'valid_from','2026-04-15')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'last_booked')::date IS DISTINCT FROM DATE '2026-05-01' THEN
    RAISE EXCEPTION 'FAIL split [rueckwirkend]: erwartet ok=false last_booked=2026-05-01, got %', v_res; END IF;
  RAISE NOTICE 'PASS split [Stichtag vor gebuchter Rate -> ok:false]';

  -- TEST 11: Ende-Eingabe ist INKLUSIV (letzter gueltiger Tag) -> gespeichert +1 Tag; Ende <= Stichtag -> ok:false
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_srp2_kita__','account_id',v_acct,
    'direction','expense','amount',300,'schedule_unit','month','first_payment_date','2026-01-01')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'valid_to','2026-12-01'));
  SELECT valid_to INTO v_to FROM finance.recurring_payments WHERE id = v_rp;
  IF v_to IS DISTINCT FROM DATE '2026-12-02' THEN
    RAISE EXCEPTION 'FAIL ende [inklusiv]: gespeichert erwartet 2026-12-02, got %', v_to; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open('2026-12-15') WHERE recurring_payment_id = v_rp AND due_date = '2026-12-01') THEN
    RAISE EXCEPTION 'FAIL ende [inklusiv]: letzte Rate 2026-12-01 nicht mehr faellig'; END IF;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',320,
    'valid_from','2026-09-01','valid_to','2026-08-31')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL ende [vor Stichtag]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS ende [inklusive Eingabe -> +1 gespeichert, letzte Rate faellig; Ende vor Stichtag -> ok:false]';

  -- TEST 12 (Review): "laeuft wieder + neuer Betrag" in EINEM Aufruf -> neue Zeile uebernimmt den genannten Status
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_srp2_gehalt2__','account_id',v_acct,
    'direction','income','amount',3000,'schedule_unit','month','first_payment_date','2026-01-28')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'status','paused'));
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',3200,
    'valid_from','2026-11-01','status','active')) INTO v_res;
  SELECT status::text INTO v_status FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL split [Status-Eingabe]: neue Zeile erwartet active, got %', v_status; END IF;
  RAISE NOTICE 'PASS split [genannter Status gilt fuer die neue Zeile]';
END $$;

-- TEST 5 (Phase L WS-3): Cashflow-Sofort-Hinweis bei Betrags-Erhoehung. Die fn liest monthly_cashflow_summary
-- (GLOBALE Single-Row-View) -> SAVEPOINT + bestehende rp neutralisieren, kontrollierten Cashflow setzen, danach
-- ROLLBACK TO SAVEPOINT. M3-KERN: bei ZUKUENFTIG datierter Erhoehung bleibt die alte Zeile aktiv (View zeigt den
-- noch geltenden Ist-Stand) -> KEINE Sofort-Note; nur bei Stichtag HEUTE spiegelt die View die neue Zeile.
SAVEPOINT srp_fold;
UPDATE finance.recurring_payments SET status = 'paused';   -- nur im Savepoint; FK-frei
DO $$
DECLARE
  v_res jsonb; v_acct int; v_exp_a int; v_exp_b int;
BEGIN
  SELECT finance.fn_create_account('{"name":"__srp_fold_acct__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- Einkommen +2000 (aktiv ueber alle Sub-Tests)
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__srp_fold_inc__','account_id',v_acct,'direction','income','amount',2000,
    'schedule_unit','month','first_payment_date',current_date::text)) INTO v_res;

  -- ===== (5a, M3) ZUKUENFTIG datierte Erhoehung -> KEINE Note =====
  -- Ausgabe -500, valid_from in der Vergangenheit (sauberer Split). net = 2000 - 500 = +1500.
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__srp_fold_exp_a__','account_id',v_acct,'direction','expense','amount',500,
    'schedule_unit','month','first_payment_date',(current_date - 30)::text)) INTO v_res;
  v_exp_a := (v_res->>'recurring_payment_id')::int;
  -- Erhoehung auf 3000 mit Stichtag in 30 Tagen: alte Zeile valid_to=Stichtag (>heute -> bleibt aktiv, -500),
  -- neue Zeile valid_from=Stichtag (>heute -> raus) -> Live-View weiter +1500 -> KEINE Note.
  SELECT finance.fn_set_recurring_payment(jsonb_build_object(
    'recurring_payment_id', v_exp_a, 'amount', 3000, 'valid_from', (current_date + 30)::text)) INTO v_res;
  IF (v_res->>'split')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [5a setup]: erwartet split=true, got %', v_res; END IF;
  IF v_res ? 'cashflow_coverage' THEN
    RAISE EXCEPTION 'FAIL [5a M3]: zukuenftig datierte Erhoehung darf KEINEN Sofort-Hinweis ausloesen, got %', v_res; END IF;
  RAISE NOTICE 'PASS [5a WS-3/M3: zukuenftig datierte Erhoehung -> kein Sofort-Hinweis (Cron faengt es)]';

  -- exp_a (alte + neue Split-Zeile, gleicher Name) pausieren -> Szenario 5b sauber
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name = '__srp_fold_exp_a__';

  -- ===== (5b) HEUTE datierte Erhoehung -> Note =====
  -- Ausgabe -500, valid_from in der Vergangenheit. net = 2000 - 500 = +1500.
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__srp_fold_exp_b__','account_id',v_acct,'direction','expense','amount',500,
    'schedule_unit','month','first_payment_date',(current_date - 30)::text)) INTO v_res;
  v_exp_b := (v_res->>'recurring_payment_id')::int;
  -- Erhoehung auf 3000 mit Stichtag HEUTE: alte Zeile valid_to=heute (raus, valid_to>heute=false), neue Zeile
  -- valid_from=heute aktiv (-3000) -> net = 2000 - 3000 = -1000 -> cashflow_coverage-Note.
  SELECT finance.fn_set_recurring_payment(jsonb_build_object(
    'recurring_payment_id', v_exp_b, 'amount', 3000, 'valid_from', current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [5b setup]: %', v_res; END IF;
  IF NOT (v_res ? 'cashflow_coverage') OR COALESCE(v_res->'cashflow_coverage'->>'note','') = '' THEN
    RAISE EXCEPTION 'FAIL [5b]: kein cashflow_coverage-Fold bei heute-datierter Erhoehung (net<0), got %', v_res; END IF;
  RAISE NOTICE 'PASS [5b WS-3: heute datierte Erhoehung kippt net<0 -> cashflow_coverage-Fold]';

  -- ===== (5c, Audit Paket 3) ETF-Sparplan ist keine Fixkosten: Einnahmen 2000, ETF 1800, Miete 500 -> 1000 =====
  -- Frueher: monthly_net = 2000 - 1800 - 1000 = -800 -> Fehlalarm. Jetzt: frei = 2000 - 1000 = +1000 -> KEINE Note.
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name = '__srp_fold_exp_b__';
  DECLARE v_depot int; v_etf int; v_rent int; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__srp_fold_depot__','stocks_depot','EUR','active', v_acct) RETURNING id INTO v_depot;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('__srp_fold_etf__', v_acct, -1800, 'month', current_date - 30, current_date - 30) RETURNING id INTO v_etf;
    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
      VALUES ('__srp_fold_etf_plan__', v_depot, 'SRPW', 'World', v_etf);
    SELECT finance.fn_create_recurring_payment(jsonb_build_object(
      'name','__srp_fold_rent__','account_id',v_acct,'direction','expense','amount',500,
      'schedule_unit','month','first_payment_date',(current_date - 30)::text)) INTO v_res;
    v_rent := (v_res->>'recurring_payment_id')::int;
    SELECT finance.fn_set_recurring_payment(jsonb_build_object(
      'recurring_payment_id', v_rent, 'amount', 1000, 'valid_from', current_date::text)) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [5c setup]: %', v_res; END IF;
    IF v_res ? 'cashflow_coverage' THEN
      RAISE EXCEPTION 'FAIL [5c]: Sparplan darf keinen Fixkosten-Hinweis ausloesen (frei +1000), got %', v_res; END IF;
    RAISE NOTICE 'PASS [5c Paket 3: Sparplan zaehlt nicht als Fixkosten -> kein cashflow_coverage]';
  END;
END $$;
ROLLBACK TO SAVEPOINT srp_fold;

-- ===== „Bank-Hinweis nur, wo er passt": executed_by am Uebertrag setzen (In-Place, Split, Kette, Ablehnungen) =====
SAVEPOINT srp_exec;
DO $$
DECLARE
  v_res JSONB; v_a INT; v_b INT; v_rp INT; v_new INT; v_plain INT; v_first TEXT := (CURRENT_DATE + 1)::text;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__srp_x_a__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__srp_x_b__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_res := finance.fn_create_recurring_transfer(jsonb_build_object('name','__srp_x_t__','from_account_id',v_a,
             'to_account_id',v_b,'amount',100,'schedule_unit','month','first_payment_date',v_first));
  v_rp := (v_res->>'recurring_payment_id')::int;

  -- [X1] In-Place: Nutzer sagt "laeuft als Dauerauftrag bei meiner Bank" -> gespeichert, Antwort traegt execution (kein Split)
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'executed_by', 'bank'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM false
     OR v_res->>'execution' IS DISTINCT FROM 'bank'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM 'bank'
     OR (v_res->'effective') ? 'execution' OR (v_res->'effective') ? 'executed_by' THEN
    RAISE EXCEPTION 'FAIL [X1] in-place executed_by=bank, got %', v_res; END IF;
  RAISE NOTICE 'PASS [X1] set executed_by in-place: gespeichert, execution=bank';

  -- [X2] ohne executed_by bleibt der gespeicherte Wert, die Antwort nennt den aufgeloesten (bank)
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'notes', 'nur Notiz'));
  IF v_res->>'execution' IS DISTINCT FROM 'bank'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM 'bank' THEN
    RAISE EXCEPTION 'FAIL [X2] ohne Angabe bleibt bank, got %', v_res; END IF;
  RAISE NOTICE 'PASS [X2] ohne executed_by bleibt der Wert';

  -- [X3] Ablehnungen: ungueltiger Wert, Zeile ohne Ziel-Konto -> {ok:false}, nichts geaendert
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'executed_by', 'auto'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM 'bank' THEN
    RAISE EXCEPTION 'FAIL [X3a] ungueltiger Wert, got %', v_res; END IF;
  v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__srp_x_plain__','account_id',v_a,
             'direction','expense','amount',30,'schedule_unit','month','first_payment_date',v_first));
  v_plain := (v_res->>'recurring_payment_id')::int;
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_plain, 'executed_by', 'bank'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_plain) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [X3b] Nicht-Uebertrag, got %', v_res; END IF;
  RAISE NOTICE 'PASS [X3] ungueltiger Wert und Nicht-Uebertrag -> ok:false ohne Aenderung';

  -- [X4] Betrag + executed_by zusammen (Split): die NEUE Zeile traegt den Wert, die noch laufende alte auch
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'amount', 120,
             'valid_from', (CURRENT_DATE + 30)::text, 'executed_by', 'manual'));
  v_new := (v_res->>'recurring_payment_id')::int;
  IF (v_res->>'split')::boolean IS DISTINCT FROM true OR v_new = v_rp OR v_res->>'execution' IS DISTINCT FROM 'manual'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_new) IS DISTINCT FROM 'manual'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'FAIL [X4] Split mit executed_by, got % / neu=% alt=%', v_res,
      (SELECT executed_by FROM finance.recurring_payments WHERE id = v_new),
      (SELECT executed_by FROM finance.recurring_payments WHERE id = v_rp); END IF;
  RAISE NOTICE 'PASS [X4] Betrag + executed_by: neue und noch laufende alte Zeile tragen den Wert';

  -- [X5] Kette: ein spaeteres Setzen auf einem Glied erreicht ALLE noch laufenden Glieder (Alarm liest den Kopf,
  --      die Uebersicht das gueltige Glied: beide muessen dasselbe zeigen)
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_new, 'executed_by', 'bank'));
  IF (SELECT count(*) FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp)) AND executed_by = 'bank') <> 2 THEN
    RAISE EXCEPTION 'FAIL [X5] Kette einheitlich bank: %', (SELECT jsonb_agg(executed_by) FROM finance.recurring_payments
                                                           WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))); END IF;
  -- und ein Split ohne neue Angabe erbt (neue Zeile traegt den bisherigen Wert)
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_new, 'amount', 140,
             'valid_from', (CURRENT_DATE + 60)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int) IS DISTINCT FROM 'bank' THEN
    RAISE EXCEPTION 'FAIL [X5b] Split erbt executed_by, got %', v_res; END IF;
  RAISE NOTICE 'PASS [X5] Kette einheitlich, Split ohne Angabe erbt';
END $$;
ROLLBACK TO SAVEPOINT srp_exec;

-- Betrag 0 ist keine Aenderung, sondern eine korrigierbare Ablehnung (kein Split)
DO $$
DECLARE v_acc INT; v_rp INT; v_res JSONB;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__test_srp0_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__test_srp0_abo__', v_acc, -15, 'month', CURRENT_DATE + 5, CURRENT_DATE - 20) RETURNING id INTO v_rp;
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'amount', 0));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT count(*) FROM finance.recurring_payments WHERE name = '__test_srp0_abo__') <> 1 THEN
    RAISE EXCEPTION 'FAIL [Betrag 0]: %', v_res; END IF;
  RAISE NOTICE 'PASS set_recurring_payment [Betrag 0 -> ok:false ohne Split]';
END $$;
ROLLBACK;
