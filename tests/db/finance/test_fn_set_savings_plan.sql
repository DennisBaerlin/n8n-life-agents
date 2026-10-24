-- tests/db/finance/test_fn_set_savings_plan.sql
-- Testet fn_set_savings_plan: Notiz-Update, Pause, Resume, Betrag-Validity-Split (neues RP,
--   altes RP beendet, plan.recurring_payment_id aktualisiert)
BEGIN;

DO $$
DECLARE
  v_result       JSONB;
  v_settle_id    INT;
  v_depot_id     INT;
  v_plan_id      INT;
  v_rp_id_old    INT;
  v_rp_id_new    INT;
  v_rp_status    TEXT;
  v_plan_status  TEXT;
  v_plan_rp      INT;
  v_old_valid_to DATE;
  v_new_amount   NUMERIC;
BEGIN

  -- Setup: Verrechnungskonto + Aktiendepot
  SELECT finance.fn_create_account(
    '{"name":"__test_ssp_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_ssp_depot__',
    'account_type', 'stocks_depot',
    'account_holder', 'Test',
    'currency', 'EUR',
    'settlement_id', v_settle_id
  )) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;
  -- Depot-Kalender: echte 7-Tage-Abstaende (sonst fragt fn_resolve_plan_schedule beim Wechsel auf woechentlich nach)
  UPDATE finance.accounts SET plan_execution_days = '{}' WHERE id = v_depot_id;

  -- Setup: Sparplan
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',              '__test_ssp_plan__',
    'depot_name',        '__test_ssp_depot__',
    'isin',              'IE00B3RBWM25',
    'symbol',            'VWCE',
    'security_name',     'Vanguard FTSE All-World',
    'amount',            100,
    'schedule_interval', 1,
    'schedule_unit',     'month',
    'first_payment_date', '2026-05-01'
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan: %', v_result->>'reason';
  END IF;
  v_plan_id  := (v_result->>'savings_plan_id')::int;
  v_rp_id_old := (v_result->>'recurring_payment_id')::int;

  -- TEST 1: Notiz-Update (in-place, kein Betragsänderung)
  SELECT finance.fn_set_savings_plan(jsonb_build_object(
    'savings_plan_name', '__test_ssp_plan__',
    'notes',             'Aktualisierte Notiz'
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [notes]: ok=false, reason=%', v_result->>'reason';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM finance.savings_plans
    WHERE id = v_plan_id AND notes = 'Aktualisierte Notiz'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [notes]: Notiz nicht gespeichert';
  END IF;
  -- rp_id darf sich nicht geändert haben
  SELECT recurring_payment_id INTO v_plan_rp
  FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_plan_rp IS DISTINCT FROM v_rp_id_old THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [notes]: rp_id geändert trotz notes-only-Update';
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [notes-Update, rp_id unverändert]';

  -- TEST 2: Pause -> plan.status=paused, rp.status=paused
  SELECT finance.fn_set_savings_plan(jsonb_build_object(
    'savings_plan_name', '__test_ssp_plan__',
    'status',            'paused'
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [pause]: ok=false, reason=%', v_result->>'reason';
  END IF;

  SELECT status::text INTO v_plan_status
  FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_plan_status IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [pause plan.status]: erwartet paused, got %',
      v_plan_status;
  END IF;

  SELECT status::text INTO v_rp_status
  FROM finance.recurring_payments WHERE id = v_rp_id_old;
  IF v_rp_status IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [pause rp.status]: erwartet paused, got %',
      v_rp_status;
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [pause -> plan.status=paused, rp.status=paused]';

  -- TEST 3: Resume -> plan.status=active, rp.status=active
  SELECT finance.fn_set_savings_plan(jsonb_build_object(
    'savings_plan_name', '__test_ssp_plan__',
    'status',            'active'
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [resume]: ok=false, reason=%', v_result->>'reason';
  END IF;

  SELECT status::text INTO v_plan_status
  FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_plan_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [resume plan.status]: erwartet active, got %',
      v_plan_status;
  END IF;

  SELECT status::text INTO v_rp_status
  FROM finance.recurring_payments WHERE id = v_rp_id_old;
  IF v_rp_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [resume rp.status]: erwartet active, got %',
      v_rp_status;
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [resume -> plan.status=active, rp.status=active]';

  -- TEST 4: Betrag-Änderung -> Validity-Split: neues RP, altes RP beendet,
  --   plan.recurring_payment_id zeigt auf neues RP
  -- Audit F2c(4): offene Alt-Vorkommen vor dem Stichtag blockieren den Split -> vorher ueberspringen
  --   (sonst buchte die Erinnerung sie spaeter als nackte Abbuchung ohne Kauf).
  PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', o.recurring_payment_id,
            'due_date', o.due_date::text))
  FROM finance.fn_recurring_due_open(CURRENT_DATE) o WHERE o.recurring_payment_id = v_rp_id_old;
  SELECT finance.fn_set_savings_plan(jsonb_build_object(
    'savings_plan_name', '__test_ssp_plan__',
    'new_amount',        150
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [amount-split]: ok=false, reason=%',
      v_result->>'reason';
  END IF;
  v_rp_id_new := (v_result->>'recurring_payment_id')::int;
  IF v_rp_id_new IS NULL OR v_rp_id_new = v_rp_id_old THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [amount-split]: neue rp_id fehlt oder identisch mit alter, got %',
      v_result;
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [amount-split]: neue rp_id=%', v_rp_id_new;

  -- Assert: altes RP hat valid_to gesetzt (beendet)
  SELECT valid_to INTO v_old_valid_to
  FROM finance.recurring_payments WHERE id = v_rp_id_old;
  IF v_old_valid_to IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [amount-split altes RP]: valid_to nicht gesetzt';
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [altes RP beendet: valid_to=%]', v_old_valid_to;

  -- Assert: neues RP hat korrekten Betrag (negativ, -150)
  SELECT amount INTO v_new_amount
  FROM finance.recurring_payments WHERE id = v_rp_id_new;
  IF v_new_amount IS DISTINCT FROM -150 THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [neues RP amount]: erwartet -150, got %', v_new_amount;
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [neues RP amount: %]', v_new_amount;

  -- Assert: plan.recurring_payment_id zeigt auf neues RP
  SELECT recurring_payment_id INTO v_plan_rp
  FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_plan_rp IS DISTINCT FROM v_rp_id_new THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [plan.rp_id nach Split]: erwartet %, got %',
      v_rp_id_new, v_plan_rp;
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [plan.recurring_payment_id aktualisiert -> %]', v_rp_id_new;

  -- TEST 5: Betrag <= 0 -> {ok:false}
  SELECT finance.fn_set_savings_plan(jsonb_build_object(
    'savings_plan_name', '__test_ssp_plan__',
    'new_amount',        0
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [amount=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [amount=0 -> ok:false]';

  -- TEST 6 (WS-B Stufe 2): Kadenz-Aenderung (schedule_unit) -> Validity-Split, neue RP traegt die
  --   neue Kadenz; der Betrag bleibt erhalten (kein new_amount uebergeben). Edge-Reviewer: ein
  --   Sparplan "50 €/Woche" muss auf "monatlich" umstellbar sein, ohne den Betrag neu nennen zu muessen.
  DECLARE
    v_rp_before INT;
    v_rp_after  INT;
    v_unit      TEXT;
    v_amt       NUMERIC;
  BEGIN
    SELECT recurring_payment_id INTO v_rp_before FROM finance.savings_plans WHERE id = v_plan_id;
    -- Audit F2c(4): eine heute faellige Ausfuehrung (Test laeuft am Monatsersten) blockiert den Split -> ueberspringen.
    PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', o.recurring_payment_id,
              'due_date', o.due_date::text))
    FROM finance.fn_recurring_due_open(CURRENT_DATE) o WHERE o.recurring_payment_id = v_rp_before;

    SELECT finance.fn_set_savings_plan(jsonb_build_object(
      'savings_plan_name', '__test_ssp_plan__',
      'schedule_unit',     'week',
      'valid_from',        (CURRENT_DATE + 1)::text
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [schedule_unit-split ok]: %', v_result->>'reason'; END IF;
    IF (v_result->>'split')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [schedule_unit]: erwartet split=true, got %', v_result; END IF;

    SELECT recurring_payment_id INTO v_rp_after FROM finance.savings_plans WHERE id = v_plan_id;
    IF v_rp_after IS DISTINCT FROM v_rp_before THEN
      NULL;  -- neue RP erwartet
    ELSE
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [schedule_unit]: rp_id unveraendert trotz Kadenz-Split';
    END IF;

    SELECT schedule_unit::text, amount INTO v_unit, v_amt
    FROM finance.recurring_payments WHERE id = v_rp_after;
    IF v_unit IS DISTINCT FROM 'week' THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [schedule_unit]: neue RP erwartet week, got %', v_unit; END IF;
    -- Betrag bleibt erhalten (TEST 4 setzte -150; Kadenz-Aenderung darf ihn nicht aendern)
    IF v_amt IS DISTINCT FROM -150 THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [schedule_unit Betrag-Erhalt]: erwartet -150, got %', v_amt; END IF;
    RAISE NOTICE 'PASS fn_set_savings_plan [schedule_unit week-Split, Betrag erhalten]';
  END;

  -- TEST 7 (Phase L WS-6): asset_class korrigierbar (orthogonal, in-place; kein Split, keine neue RP).
  DECLARE v_cls TEXT; v_rp_pre INT; v_rp_post INT; BEGIN
    SELECT recurring_payment_id INTO v_rp_pre FROM finance.savings_plans WHERE id = v_plan_id;
    SELECT finance.fn_set_savings_plan(jsonb_build_object(
      'savings_plan_name','__test_ssp_plan__','asset_class','gold')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [asset_class ok]: %', v_result->>'reason'; END IF;
    SELECT asset_class, recurring_payment_id INTO v_cls, v_rp_post FROM finance.savings_plans WHERE id = v_plan_id;
    IF v_cls IS DISTINCT FROM 'gold' THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [asset_class set]: erwartet gold, got %', v_cls; END IF;
    -- reine Anlageklasse-Aenderung darf KEINEN Validity-Split ausloesen (rp_id unveraendert)
    IF v_rp_post IS DISTINCT FROM v_rp_pre THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [asset_class split]: rp_id geaendert trotz reiner Tag-Aenderung'; END IF;
    RAISE NOTICE 'PASS fn_set_savings_plan [asset_class in-place korrigiert, kein Split]';

    -- ungueltiges Format -> {ok:false}, Tag bleibt 'gold'
    SELECT finance.fn_set_savings_plan(jsonb_build_object(
      'savings_plan_name','__test_ssp_plan__','asset_class','S&P 500')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [asset_class bad format]: erwartet ok=false, got %', v_result; END IF;
    SELECT asset_class INTO v_cls FROM finance.savings_plans WHERE id = v_plan_id;
    IF v_cls IS DISTINCT FROM 'gold' THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [asset_class bad format]: Tag trotz ok=false veraendert, got %', v_cls; END IF;
    RAISE NOTICE 'PASS fn_set_savings_plan [ungueltiges asset_class-Format -> ok:false, Tag unveraendert]';

    -- Atomaritaet (Cold-Eyes): kombinierter Aufruf new_amount<=0 + asset_class -> {ok:false} OHNE Teil-Mutation.
    -- Die orthogonale asset_class darf NICHT geschrieben werden, obwohl die fn das Feld kennt (Split-Vorbedingung
    -- wird VOR den orthogonalen UPDATEs geprueft -> der korrigierbare {ok:false}-Pfad mutiert nichts). Tag bleibt 'gold'.
    SELECT finance.fn_set_savings_plan(jsonb_build_object(
      'savings_plan_name','__test_ssp_plan__','new_amount',-5,'asset_class','momentum')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [atomar combined]: erwartet ok=false (new_amount<=0), got %', v_result; END IF;
    SELECT asset_class INTO v_cls FROM finance.savings_plans WHERE id = v_plan_id;
    IF v_cls IS DISTINCT FROM 'gold' THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [atomar combined]: asset_class bei {ok:false} mutiert (Teil-Write), erwartet gold, got %', v_cls; END IF;
    RAISE NOTICE 'PASS fn_set_savings_plan [Atomaritaet: new_amount<=0 + asset_class -> ok:false, kein Teil-Write]';
  END;

  -- TEST 8-9 (Audit F2): offene Alt-Vorkommen blockieren den Split; ein pausierter Plan bleibt nach dem Split pausiert.
  DECLARE v_rp2 INT; v_new2 INT; v_st TEXT; BEGIN
    SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_ssp_plan2__','depot_name','__test_ssp_depot__',
      'isin','IE00B4L5Y983','symbol','IUSQ','security_name','iShares MSCI World','amount',50,'schedule_interval',1,
      'schedule_unit','month','first_payment_date',(CURRENT_DATE - 10)::text)) INTO v_result;
    v_rp2 := (v_result->>'recurring_payment_id')::int;
    SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_plan2__','new_amount',60)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [offene Alt-Vorkommen]: erwartet ok=false, got %', v_result; END IF;
    RAISE NOTICE 'PASS fn_set_savings_plan [offenes Vorkommen vor Stichtag -> ok:false]';

    PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp2,
      'due_date', (CURRENT_DATE - 10)::text));
    PERFORM finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_plan2__','status','paused'));
    SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_plan2__','new_amount',60)) INTO v_result;
    v_new2 := (v_result->>'recurring_payment_id')::int;
    SELECT status::text INTO v_st FROM finance.recurring_payments WHERE id = v_new2;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR v_st IS DISTINCT FROM 'paused' THEN
      RAISE EXCEPTION 'FAIL fn_set_savings_plan [pausiert bleibt pausiert]: ok=% rp.status=%', v_result->>'ok', v_st; END IF;
    RAISE NOTICE 'PASS fn_set_savings_plan [Split eines pausierten Plans -> neue Rate bleibt paused]';
  END;

END $$;


-- TEST 10 (C8, Backlog-Bugfix-Runde): savings_squeeze-Fold auch auf dem set-Pfad. Die Fold-fn liest die GLOBALE
-- Single-Row-View monthly_cashflow_summary -> alle rp neutralisieren (Dateiende, das ROLLBACK raeumt), kontrollierten Cashflow setzen.
-- Einnahmen 2000, Miete 500; Sparplan 1800 pausiert -> gesund (kein Fold); wieder aktiv -> Kontoveraenderung -300
-- -> savings_squeeze im {ok:true}-Return.
DO $$
DECLARE
  v_result jsonb; v_giro int;
BEGIN
  UPDATE finance.recurring_payments SET status = 'paused';   -- kontrollierter Cashflow (Dateiende -> ROLLBACK raeumt)
  PERFORM core.fn_notify_resolve('finance', 'savings_squeeze');
  SELECT (finance.fn_create_account('{"name":"__test_ssp_fold_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_giro;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__test_ssp_fold_salary__', v_giro, 2000, 'month', current_date, current_date),
    ('__test_ssp_fold_rent__',   v_giro, -500, 'month', current_date, current_date);
  SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_ssp_fold_plan__','depot_name','__test_ssp_depot__',
    'isin','IE00B4L5Y983','symbol','IUSQ','security_name','iShares MSCI World','amount',1800,'schedule_interval',1,
    'schedule_unit','month','first_payment_date',CURRENT_DATE::text)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL Sparplan: %', v_result; END IF;
  -- auch das ANLEGEN eines Sparplans faltet den Hinweis (fn_create_savings_plan)
  IF (v_result->'savings_squeeze'->>'account_change')::numeric IS DISTINCT FROM -300.00 THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [fold]: neuer Sparplan muss savings_squeeze (-300) falten, got %', v_result; END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [neuer Sparplan leert das Girokonto -> savings_squeeze]';

  -- reine Notiz-Aenderung aendert keine Rate -> kein Fold, auch bei frei gegebenem Latch
  PERFORM core.fn_notify_resolve('finance', 'savings_squeeze');
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_fold_plan__','notes','nur Notiz')) INTO v_result;
  IF v_result ? 'savings_squeeze' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [fold notiz]: Notiz-Edit darf nicht warnen, got %', v_result; END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [Notiz-Edit -> kein Fold]';

  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_fold_plan__','status','paused')) INTO v_result;
  IF v_result ? 'savings_squeeze' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [fold gesund]: pausierter Plan darf nicht warnen, got %', v_result; END IF;

  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_fold_plan__','status','active')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (v_result->'savings_squeeze'->>'account_change')::numeric IS DISTINCT FROM -300.00 THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [fold]: Reaktivierung muss savings_squeeze (-300) falten, got %', v_result; END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [Reaktivierung leert das Girokonto -> savings_squeeze im Return]';
END $$;

-- Feste Monatstage (Depot-Kalender): Kadenzwechsel wird aus dem Kalender abgeleitet, eine reine Tage-Aenderung
-- splittet, ein Stichtag ausserhalb des Kalenders -> ok:false + naechster Tag, Kalender-Korrektur per Nutzer-Antwort.
DO $$
DECLARE
  v_result JSONB; v_settle INT; v_tr INT; v_r finance.recurring_payments%ROWTYPE;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__test_ssp_days_settle__', 'cash', 'EUR', 'active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id)
    VALUES ('__test_ssp_days_tr__', 'stocks_depot', 'Trade Republic', 'EUR', 'active', v_settle) RETURNING id INTO v_tr;
  SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_ssp_days__','depot_name','__test_ssp_days_tr__',
    'isin','IE00B5BMR087','symbol','CSPX','security_name','Beispiel','amount',100,'schedule_unit','week',
    'first_payment_date','2027-01-02')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL days plan: %', v_result; END IF;

  -- Stichtag ausserhalb des Kalenders -> ok:false + naechster moeglicher Tag, kein Split
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_days__',
    'schedule_unit','week','schedule_interval',2,'valid_from','2027-03-05')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'next_possible_date' IS DISTINCT FROM '2027-03-09' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [days off-calendar]: %', v_result; END IF;

  -- woechentlich -> zweimal monatlich ab dem 9.: Split auf {9,23}
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_days__',
    'schedule_unit','week','schedule_interval',2,'valid_from','2027-03-09')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'split')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [days week/2]: %', v_result; END IF;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int;
  IF v_r.schedule_days_of_month IS DISTINCT FROM '{9,23}'::smallint[] OR v_r.monthly_equivalent <> -200.00 THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [days week/2]: days=% me=%', v_r.schedule_days_of_month, v_r.monthly_equivalent; END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [Kadenzwechsel aus dem Depot-Kalender: 9./23., 200/Monat]';

  -- nur schedule_interval genannt ("jetzt jede Woche" = interval 1): Basis-Einheit ist der NUTZER-Rhythmus der
  -- Tage-Zeile (week), nicht das gespeicherte 'month' -> 4 Tage, nie "jeden Monat einmal"
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_days__',
    'schedule_interval',1,'valid_from','2027-03-16')) INTO v_result;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR v_r.schedule_days_of_month IS DISTINCT FROM '{2,9,16,23}'::smallint[]
     OR v_result->>'schedule_unit' IS DISTINCT FROM 'month' OR v_result->>'schedule_days' IS DISTINCT FROM '2, 9, 16, 23' THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [interval only]: % days=%', v_result, v_r.schedule_days_of_month; END IF;
  -- und zurueck auf "alle zwei Wochen" nur per Intervall, Stichtag am 23. -> jeder zweite Tag ab dem 23. = {9,23}
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_days__',
    'schedule_interval',2,'valid_from','2027-03-23')) INTO v_result;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int;
  IF v_r.schedule_days_of_month IS DISTINCT FROM '{9,23}'::smallint[] THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [interval 2 only]: % days=%', v_result, v_r.schedule_days_of_month; END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [nur Intervall: Basis = Nutzer-Rhythmus der Tage-Zeile]';

  -- reiner Betrag: Tage bleiben
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_days__',
    'new_amount',150,'valid_from','2027-04-01')) INTO v_result;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int;
  IF v_r.schedule_days_of_month IS DISTINCT FROM '{9,23}'::smallint[] OR v_r.monthly_equivalent <> -300.00 THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [days amount]: days=% me=%', v_r.schedule_days_of_month, v_r.monthly_equivalent; END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [Betrags-Split behaelt die Tage]';

  -- Kalender-Korrektur durch den Nutzer ({5,20}) + woechentlich -> ok:false (nur 2 Termine/Monat), kein Write
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_days__',
    'schedule_unit','week','schedule_interval',1,'valid_from','2027-05-05','depot_execution_days','5,20')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT plan_execution_days FROM finance.accounts WHERE id = v_tr) IS DISTINCT FROM '{2,9,16,23}'::smallint[] THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [calendar fix + weekly]: %', v_result; END IF;
  -- zweimal monatlich mit dem korrigierten Kalender -> {5,20}, Kalender am Depot gespeichert
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_ssp_days__',
    'schedule_unit','week','schedule_interval',2,'valid_from','2027-05-05','depot_execution_days','5,20')) INTO v_result;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR v_r.schedule_days_of_month IS DISTINCT FROM '{5,20}'::smallint[]
     OR (SELECT plan_execution_days FROM finance.accounts WHERE id = v_tr) IS DISTINCT FROM '{5,20}'::smallint[] THEN
    RAISE EXCEPTION 'FAIL fn_set_savings_plan [calendar fix]: % days=%', v_result, v_r.schedule_days_of_month; END IF;
  RAISE NOTICE 'PASS fn_set_savings_plan [Kalender-Korrektur per Nutzer-Antwort]';
END $$;

ROLLBACK;
