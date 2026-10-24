-- tests/db/finance/test_fn_set_account_interest.sql
-- Testet fn_set_account_interest: erste Zeile, Folge-Zeile schliesst offene (EXCLUDE-Constraint),
-- korrigierbare Faelle (rate negativ, valid_from nicht nach offener Zeile)
BEGIN;

DO $$
DECLARE
  v_res       JSONB;
  v_acct      INT;
  v_count     INT;
  v_old_to    DATE;
  v_new_rate  NUMERIC;
BEGIN

  -- Setup: Konto OHNE Zinszeile
  SELECT finance.fn_create_account('{"name":"__test_int_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- TEST 1: erste Zinszeile (keine offene vorhanden -> closed_previous=false)
  SELECT finance.fn_set_account_interest(jsonb_build_object(
    'account_id', v_acct, 'annual_rate', 2.0, 'schedule_unit', 'year', 'valid_from', '2026-01-01'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'closed_previous')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_account_interest [erste Zeile]: %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_account_interest [erste Zinszeile, closed_previous=false]';

  -- TEST 2: Folge-Zinssatz -> alte Zeile wird per valid_to geschlossen, neue offen
  SELECT finance.fn_set_account_interest(jsonb_build_object(
    'account_id', v_acct, 'annual_rate', 3.5, 'schedule_unit', 'year', 'valid_from', '2026-07-01'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'closed_previous')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_account_interest [folge]: erwartet closed_previous=true, got %', v_res;
  END IF;

  -- Assert: genau eine offene Zeile (valid_to IS NULL) mit 3.5; alte hat valid_to=2026-07-01
  SELECT count(*) INTO v_count FROM finance.account_interest_rates
   WHERE account_id = v_acct AND valid_to IS NULL;
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL set_account_interest [eine offene]: erwartet 1, got %', v_count;
  END IF;
  SELECT annual_rate INTO v_new_rate FROM finance.account_interest_rates
   WHERE account_id = v_acct AND valid_to IS NULL;
  IF v_new_rate IS DISTINCT FROM 3.5 THEN
    RAISE EXCEPTION 'FAIL set_account_interest [offener satz]: erwartet 3.5, got %', v_new_rate;
  END IF;
  SELECT valid_to INTO v_old_to FROM finance.account_interest_rates
   WHERE account_id = v_acct AND annual_rate = 2.0;
  IF v_old_to IS DISTINCT FROM DATE '2026-07-01' THEN
    RAISE EXCEPTION 'FAIL set_account_interest [alte geschlossen]: erwartet 2026-07-01, got %', v_old_to;
  END IF;
  RAISE NOTICE 'PASS set_account_interest [Folge-Satz: alte geschlossen, neue offen, kein Overlap]';

  -- TEST 3: rate negativ -> {ok:false}
  SELECT finance.fn_set_account_interest(jsonb_build_object(
    'account_id', v_acct, 'annual_rate', -1, 'valid_from', '2027-01-01'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_account_interest [neg rate]: erwartet ok=false, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_account_interest [neg rate -> ok:false]';

  -- TEST 3b: Gutschrift am vorletzten Tag (-2) gibt es nur fuer Zahlungen -> {ok:false} vor dem Zins-Raster
  SELECT finance.fn_set_account_interest(jsonb_build_object(
    'account_id', v_acct, 'annual_rate', 2, 'valid_from', '2027-01-01',
    'schedule_unit', 'month', 'schedule_interval', 1, 'schedule_day_of_month', -2
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT ILIKE '%-2%' THEN
    RAISE EXCEPTION 'FAIL set_account_interest [dom -2]: erwartet ok=false mit -2-Grund, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_account_interest [dom -2 -> ok:false]';

  -- TEST 4: valid_from nicht nach offener Zeile (2026-07-01) -> {ok:false} + kein Overlap
  SELECT finance.fn_set_account_interest(jsonb_build_object(
    'account_id', v_acct, 'annual_rate', 4.0, 'valid_from', '2026-05-01'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_account_interest [valid_from zu frueh]: erwartet ok=false, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_account_interest [valid_from <= offene -> ok:false]';

  -- TEST 5: Backdating in eine HISTORISCHE (geschlossene) Periode ohne offene Zeile
  -- -> exclusion_violation wird abgefangen -> {ok:false} (kein harter RAISE/Owner-Alert).
  DECLARE
    v_acct2 INT;
  BEGIN
    SELECT finance.fn_create_account('{"name":"__test_int_hist__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
    v_acct2 := (v_res->>'account_id')::int;
    -- Geschlossene historische Zinszeile [2026-01-01, 2026-07-01); KEINE offene Zeile.
    INSERT INTO finance.account_interest_rates
        (account_id, annual_rate, schedule_interval, schedule_unit, valid_from, valid_to)
    VALUES (v_acct2, 1.0, 1, 'year', '2026-01-01', '2026-07-01');
    -- Backdating mit valid_from im historischen Bereich -> [2026-03-01, inf) ueberlappt -> exclusion.
    SELECT finance.fn_set_account_interest(jsonb_build_object(
      'account_id', v_acct2, 'annual_rate', 2.5, 'valid_from', '2026-03-01'
    )) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL set_account_interest [backdate-overlap]: erwartet ok=false (exclusion abgefangen), got %', v_res;
    END IF;
    RAISE NOTICE 'PASS set_account_interest [backdate in historische Periode -> exclusion abgefangen -> ok:false]';
  END;

  -- TEST 6 (Zins-Ausbau): Methoden-Override + Carry-forward, auto_post-Default, posting_day_of_month
  DECLARE
    v_acct3 INT;
    v_acct4 INT;
    v_dc    TEXT;
    v_ap    BOOLEAN;
    v_pd    SMALLINT;
  BEGIN
    SELECT finance.fn_create_account('{"name":"__test_int_conv__","account_type":"cash"}'::jsonb) INTO v_res;
    v_acct3 := (v_res->>'account_id')::int;

    -- erste Zeile mit Methoden-Override 30E/360 (schlaegt cash-Default ACT/365) + Arrears posting 5; monatlich -> auto_post false
    SELECT finance.fn_set_account_interest(jsonb_build_object(
      'account_id', v_acct3, 'annual_rate', 2.0, 'schedule_unit', 'month', 'schedule_day_of_month', -1,
      'day_count_convention', '30E/360', 'posting_day_of_month', 5, 'valid_from', '2026-01-01')) INTO v_res;
    SELECT day_count_convention, auto_post, posting_day_of_month INTO v_dc, v_ap, v_pd
      FROM finance.account_interest_rates WHERE account_id = v_acct3 AND valid_to IS NULL;
    IF v_dc IS DISTINCT FROM '30E/360' THEN RAISE EXCEPTION 'FAIL [dc override]: erwartet 30E/360, got %', v_dc; END IF;
    IF v_ap IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [auto_post monthly]: erwartet false, got %', v_ap; END IF;
    IF v_pd IS DISTINCT FROM 5 THEN RAISE EXCEPTION 'FAIL [posting]: erwartet 5, got %', v_pd; END IF;
    RAISE NOTICE 'PASS [Override 30E/360 + auto_post monthly=false + posting=5]';

    -- Folge-Zeile OHNE day_count-Override -> Carry-forward der Vorgaengerzeile (30E/360, NICHT cash-Default ACT/365)
    SELECT finance.fn_set_account_interest(jsonb_build_object(
      'account_id', v_acct3, 'annual_rate', 3.0, 'schedule_unit', 'month', 'valid_from', '2026-07-01')) INTO v_res;
    SELECT day_count_convention INTO v_dc FROM finance.account_interest_rates WHERE account_id = v_acct3 AND valid_to IS NULL;
    IF v_dc IS DISTINCT FROM '30E/360' THEN RAISE EXCEPTION 'FAIL [dc carry-forward]: erwartet 30E/360, got %', v_dc; END IF;
    RAISE NOTICE 'PASS [day_count Carry-forward der Vorgaengerzeile]';

    -- frisches cash-Konto, taeglich, kein Override -> day_count cash-Default ACT/365 + auto_post-Default true
    SELECT finance.fn_create_account('{"name":"__test_int_daily_set__","account_type":"cash"}'::jsonb) INTO v_res;
    v_acct4 := (v_res->>'account_id')::int;
    SELECT finance.fn_set_account_interest(jsonb_build_object(
      'account_id', v_acct4, 'annual_rate', 1.5, 'schedule_unit', 'day', 'valid_from', '2026-01-01')) INTO v_res;
    SELECT day_count_convention, auto_post INTO v_dc, v_ap
      FROM finance.account_interest_rates WHERE account_id = v_acct4 AND valid_to IS NULL;
    IF v_dc IS DISTINCT FROM 'ACT/365' THEN RAISE EXCEPTION 'FAIL [dc cash default]: erwartet ACT/365, got %', v_dc; END IF;
    IF v_ap IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [auto_post daily]: erwartet true, got %', v_ap; END IF;
    RAISE NOTICE 'PASS [cash-Default ACT/365 + auto_post daily=true]';
  END;

  -- TEST 7 (WS-Z4): Zins auf einen nicht-zins-faehigen Kontotyp (Kredit) -> {ok:false}, kein Write
  DECLARE
    v_loan INT;
  BEGIN
    -- loan-Konto direkt (fn_create_account lehnt loan ab; Kredit-Konten legt nur fn_create_loan an)
    WITH i AS (INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__test_int_loan_set__', 'loan', 'EUR') RETURNING id)
      SELECT jsonb_build_object('account_id', id) INTO v_res FROM i;
    v_loan := (v_res->>'account_id')::int;
    SELECT finance.fn_set_account_interest(jsonb_build_object(
      'account_id', v_loan, 'annual_rate', 3.0, 'valid_from', '2026-01-01')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL set_account_interest [loan ineligible]: erwartet ok=false, got %', v_res;
    END IF;
    IF EXISTS (SELECT 1 FROM finance.account_interest_rates WHERE account_id = v_loan) THEN
      RAISE EXCEPTION 'FAIL set_account_interest [loan ineligible]: es darf KEINE Zinszeile geschrieben sein';
    END IF;
    RAISE NOTICE 'PASS set_account_interest [Kredit nicht zins-faehig -> ok:false, kein Write]';
  END;

  -- TEST 8 (Live-Befund 2026-10-24): kein erfundener Rhythmus; Pflicht-Pruefung auf den WIRKSAMEN Werten;
  -- Tag nur bei gleicher Einheit geerbt; Vorschau liefert die erste Gutschrift (Karte).
  DECLARE
    v_a INT;
    v_p JSONB;
  BEGIN
    SELECT finance.fn_create_account('{"name":"__test_int_rules__","account_type":"cash"}'::jsonb) INTO v_res;
    v_a := (v_res->>'account_id')::int;
    -- (a) erster Satz ohne Rhythmus -> ok:false, kein Write
    v_p := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_a, 'annual_rate', 2.5, 'valid_from', '2026-10-24'));
    IF (v_p->>'ok')::boolean IS DISTINCT FROM false OR v_p->>'reason' NOT LIKE '%schedule_unit%' THEN
      RAISE EXCEPTION 'FAIL [8a erster Satz ohne Rhythmus]: %', v_p; END IF;
    SELECT finance.fn_set_account_interest(jsonb_build_object('account_id', v_a, 'annual_rate', 2.5, 'valid_from', '2026-10-24')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false
       OR EXISTS (SELECT 1 FROM finance.account_interest_rates WHERE account_id = v_a) THEN
      RAISE EXCEPTION 'FAIL [8a set ohne Rhythmus]: %', v_res; END IF;
    -- (b) monatlich ohne Tag -> ok:false
    v_p := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_a, 'annual_rate', 2.5, 'schedule_unit', 'month', 'valid_from', '2026-10-24'));
    IF (v_p->>'ok')::boolean IS DISTINCT FROM false OR v_p->>'reason' NOT LIKE '%schedule_day_of_month%' THEN
      RAISE EXCEPTION 'FAIL [8b monatlich ohne Tag]: %', v_p; END IF;
    -- (c) monatlich zum Monatsende, Arrears am 1. -> erste Gutschrift 01.11.
    v_p := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_a, 'annual_rate', 2.5, 'schedule_unit', 'month',
             'schedule_day_of_month', -1, 'posting_day_of_month', 1, 'valid_from', '2026-10-24'));
    IF (v_p->>'ok')::boolean IS DISTINCT FROM true OR v_p->>'first_period_end' IS DISTINCT FROM '2026-10-31'
       OR v_p->>'first_credit_date' IS DISTINCT FROM '2026-11-01' THEN
      RAISE EXCEPTION 'FAIL [8c Vorschau Monatsende]: %', v_p; END IF;
    SELECT finance.fn_set_account_interest(jsonb_build_object('account_id', v_a, 'annual_rate', 2.5, 'schedule_unit', 'month',
             'schedule_day_of_month', -1, 'posting_day_of_month', 1, 'valid_from', '2026-10-24')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [8c set Monatsende]: %', v_res; END IF;
    -- (d) reiner Satzwechsel ohne Rhythmus -> erbt die offene Kadenz (month/-1/1), erste Gutschrift im alten Raster
    v_p := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_a, 'annual_rate', 2.75, 'valid_from', '2026-11-10'));
    IF (v_p->>'ok')::boolean IS DISTINCT FROM true OR v_p->>'schedule_unit' IS DISTINCT FROM 'month'
       OR (v_p->>'schedule_day_of_month')::int IS DISTINCT FROM -1 OR v_p->>'first_period_end' IS DISTINCT FROM '2026-11-30' THEN
      RAISE EXCEPTION 'FAIL [8d reiner Satzwechsel]: %', v_p; END IF;
    -- (e) Einheitswechsel month/-1 -> year ohne Tag: Tag wird NICHT geerbt -> Jahrestag
    v_p := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_a, 'annual_rate', 2.75, 'schedule_unit', 'year', 'valid_from', '2026-11-10'));
    IF (v_p->>'ok')::boolean IS DISTINCT FROM true OR v_p->>'schedule_day_of_month' IS NOT NULL
       OR v_p->>'posting_day_of_month' IS NOT NULL OR v_p->>'first_period_end' IS DISTINCT FROM '2027-11-10' THEN
      RAISE EXCEPTION 'FAIL [8e Einheitswechsel -> Jahrestag]: %', v_p; END IF;
  END;
  -- (f) Altzeile monatlich OHNE Tag (vor dem Gesetz geschrieben): reiner Satzwechsel bleibt erlaubt
  DECLARE
    v_b INT;
    v_p JSONB;
  BEGIN
    SELECT finance.fn_create_account('{"name":"__test_int_legacy__","account_type":"cash"}'::jsonb) INTO v_res;
    v_b := (v_res->>'account_id')::int;
    INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, valid_from)
    VALUES (v_b, 1.0, 1, 'month', '2026-01-10');
    v_p := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_b, 'annual_rate', 1.5, 'valid_from', '2026-10-24'));
    IF (v_p->>'ok')::boolean IS DISTINCT FROM true OR v_p->>'schedule_day_of_month' IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [8f Altzeile Satzwechsel]: %', v_p; END IF;
    -- dieselbe Altzeile, Kadenzwechsel auf alle 2 Monate ohne Tag -> Pflicht greift
    v_p := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_b, 'annual_rate', 1.5, 'schedule_interval', 2, 'valid_from', '2026-10-24'));
    IF (v_p->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [8f Altzeile Kadenzwechsel ohne Tag]: %', v_p; END IF;
  END;
  RAISE NOTICE 'PASS set_account_interest [8 Rhythmus Pflicht, Tag-Erbe nur bei gleicher Einheit, erste Gutschrift]';

END $$;

ROLLBACK;
