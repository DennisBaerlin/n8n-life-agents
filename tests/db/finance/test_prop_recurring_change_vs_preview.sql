-- tests/db/finance/test_prop_recurring_change_vs_preview.sql
-- Eigenschafts-Test: eine Aenderung an einer wiederkehrenden Zahlung gegen die abgeleitete Vorschau, ueber viele
-- Kombinationen. Gelesen wird nur ueber die lesende Seite (fn_upcoming_payments, fn_account_planned_flows,
-- fn_account_projection, fn_app_payment_occurrences), nie aus recurring_payments nachgerechnet.
--   P1 Betrags-Wechsel (Validity-Split) an jedem Stichtag: die Termine der Kette sind dieselben wie vorher (keiner
--      doppelt, keiner verloren); vor dem Stichtag alter Betrag, ab dem Stichtag neuer; auch ueber zwei Wechsel
--      (predecessor_id-Kette aus drei Gliedern) und bei befristeter Zahlung (Ende bleibt)
--   P2 alle lesenden Sichten zeigen dieselben Termine und Betraege; ein Uebertrag erscheint bei der Quelle als Abgang
--      und beim Ziel als gleich grosser Eingang
--   P3 Buchen eines Termins nimmt genau diesen aus der Vorschau und laesst den voraussichtlichen Endstand gleich;
--      Stornieren der Buchung stellt die Vorschau wieder her
--   P4 Pausieren leert die Vorschau, Fortsetzen stellt sie wieder her (auch bei einer Kette aus zwei Gliedern)
--   P5 "startet am" (upcoming_recurring_payments.starts_on) = erster Termin der Vorschau, auch bei abweichendem Geltungsbeginn
-- Jeder Fall laeuft in einem eigenen Savepoint (SQLSTATE RS000 rollt ihn zurueck), damit die Konten je Fall leer sind.
-- Feste Daten im Jahr 2031: Raster, Split und Vorschau-Fenster haengen dort nicht von "heute" ab.
BEGIN;

CREATE FUNCTION pg_temp.sig_upcoming(p_ids int[], p_from date, p_until date) RETURNS text LANGUAGE sql AS $f$
  SELECT COALESCE(string_agg(u.due_date::text || '=' || u.amount::text, ',' ORDER BY u.due_date, u.amount), '')
  FROM finance.fn_upcoming_payments(p_from, p_until) u WHERE u.recurring_payment_id = ANY (p_ids);
$f$;
CREATE FUNCTION pg_temp.sig_flows(p_account int, p_from date, p_until date) RETURNS text LANGUAGE sql AS $f$
  SELECT COALESCE(string_agg(f.due_date::text || '=' || f.amount::text, ',' ORDER BY f.due_date, f.amount), '')
  FROM finance.fn_account_planned_flows(p_account, p_from, p_until) f;
$f$;
CREATE FUNCTION pg_temp.sig_projection(p_account int, p_from date, p_until date) RETURNS text LANGUAGE sql AS $f$
  SELECT COALESCE(string_agg(x.day::text || '=' || x.amt::text, ',' ORDER BY x.day, x.amt), '')
  FROM (SELECT p.day, p.planned_in AS amt FROM finance.fn_account_projection(p_account, p_from, p_until, 0) p WHERE p.planned_in <> 0
        UNION ALL
        SELECT p.day, p.planned_out FROM finance.fn_account_projection(p_account, p_from, p_until, 0) p WHERE p.planned_out <> 0) x;
$f$;
CREATE FUNCTION pg_temp.sig_app(p_account int, p_from date, p_until date) RETURNS text LANGUAGE sql AS $f$
  SELECT COALESCE(string_agg((r->>'date') || '=' || ((r->>'amount')::numeric(12,2))::text, ',' ORDER BY (r->>'date')::date, (r->>'amount')::numeric), '')
  FROM jsonb_array_elements(finance.fn_app_payment_occurrences(p_account, p_from, p_until, true, NULL)->'rows') r;
$f$;
CREATE FUNCTION pg_temp.end_balance(p_account int, p_from date, p_until date) RETURNS numeric LANGUAGE sql AS $f$
  SELECT p.bal FROM finance.fn_account_projection(p_account, p_from, p_until, 0) p ORDER BY p.day DESC LIMIT 1;
$f$;

DO $$
DECLARE
  c_from  CONSTANT DATE := DATE '2030-12-01';
  c_until CONSTANT DATE := DATE '2032-01-31';
  v_res JSONB; v_giro INT; v_pot INT; v_rp INT; v_new INT; v_new2 INT;
  v_doms INT[] := ARRAY[NULL,1,15,28,-1,-2];
  v_dom INT; v_eff DATE; v_eff2 DATE; v_bounded BOOLEAN; v_k INT;
  v_before TEXT; v_after TEXT; v_dates0 DATE[]; v_dates1 DATE[]; v_sig TEXT; v_end0 NUMERIC; v_end1 NUMERIC;
  v_n_split INT := 0; v_n_read INT := 0; v_n_book INT := 0; v_n_pause INT := 0; v_n_start INT := 0;
  r RECORD; o RECORD; v_tx INT; v_cnt INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__prop_cvp_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__prop_cvp_topf__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_pot;

  -- P1: Betrags-Wechsel an jedem 3. Tag zweier Monate, je Monatstag-Variante, offen und befristet
  FOREACH v_dom IN ARRAY v_doms LOOP
    FOREACH v_bounded IN ARRAY ARRAY[false, true] LOOP
      FOR v_k IN 0..60 BY 3 LOOP
        v_eff := DATE '2031-04-01' + v_k;
        BEGIN
          v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__prop_cvp_p1__','account_id',v_giro,
            'direction','expense','amount',100,'schedule_unit','month','first_payment_date','2031-01-15')
            || CASE WHEN v_dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', v_dom) END
            || CASE WHEN v_bounded THEN jsonb_build_object('valid_to','2031-10-20') ELSE '{}'::jsonb END);
          IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL P1 setup: %', v_res; END IF;
          v_rp := (v_res->>'recurring_payment_id')::int;
          SELECT array_agg(u.due_date ORDER BY u.due_date) INTO v_dates0 FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id = v_rp;
          v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',120,'valid_from',v_eff));
          IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'FAIL P1 [dom=% befristet=% stichtag=%]: Split abgelehnt %', v_dom, v_bounded, v_eff, v_res; END IF;
          v_new := (v_res->>'recurring_payment_id')::int;
          SELECT array_agg(u.due_date ORDER BY u.due_date) INTO v_dates1 FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id IN (v_rp, v_new);
          IF v_dates1 IS DISTINCT FROM v_dates0 THEN
            RAISE EXCEPTION 'FAIL P1 [dom=% befristet=% stichtag=%]: Termine vorher % nachher %', v_dom, v_bounded, v_eff, v_dates0, v_dates1; END IF;
          IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id IN (v_rp, v_new)
                       AND u.amount IS DISTINCT FROM CASE WHEN u.due_date < v_eff THEN -100 ELSE -120 END) THEN
            RAISE EXCEPTION 'FAIL P1 [dom=% befristet=% stichtag=%]: Betrag passt nicht zum Stichtag: %', v_dom, v_bounded, v_eff,
              pg_temp.sig_upcoming(ARRAY[v_rp, v_new], c_from, c_until); END IF;
          IF (SELECT sum(planned_out) FROM finance.fn_account_projection(v_giro, c_from, c_until, 0))
             IS DISTINCT FROM -(SELECT sum(CASE WHEN d < v_eff THEN 100 ELSE 120 END) FROM unnest(v_dates0) d) THEN
            RAISE EXCEPTION 'FAIL P1 [dom=% befristet=% stichtag=%]: Summe der Kontovorschau weicht ab', v_dom, v_bounded, v_eff; END IF;
          -- zweiter Wechsel 40 Tage spaeter: Kette aus drei Gliedern, Termine weiter unveraendert
          v_eff2 := v_eff + 40;
          v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_new,'amount',90,'valid_from',v_eff2));
          IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'FAIL P1 [dom=% befristet=% stichtag2=%]: zweiter Split abgelehnt %', v_dom, v_bounded, v_eff2, v_res; END IF;
          v_new2 := (v_res->>'recurring_payment_id')::int;
          IF (SELECT count(*) FROM finance.fn_recurring_lineage(v_rp)) <> 3 THEN
            RAISE EXCEPTION 'FAIL P1: Kette hat nicht drei Glieder'; END IF;
          SELECT array_agg(u.due_date ORDER BY u.due_date) INTO v_dates1 FROM finance.fn_upcoming_payments(c_from, c_until) u
            WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
          IF v_dates1 IS DISTINCT FROM v_dates0 THEN
            RAISE EXCEPTION 'FAIL P1 [dom=% befristet=% stichtage=%/%]: Termine nach zwei Wechseln % statt %', v_dom, v_bounded, v_eff, v_eff2, v_dates1, v_dates0; END IF;
          IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))
                       AND u.amount IS DISTINCT FROM CASE WHEN u.due_date < v_eff THEN -100 WHEN u.due_date < v_eff2 THEN -120 ELSE -90 END) THEN
            RAISE EXCEPTION 'FAIL P1 [dom=% befristet=% stichtage=%/%]: Betraege nach zwei Wechseln', v_dom, v_bounded, v_eff, v_eff2; END IF;
          v_n_split := v_n_split + 1;
          RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
        EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
        END;
      END LOOP;
    END LOOP;
  END LOOP;

  -- P2 + P3 + P4 je Zahlungsart
  FOR r IN SELECT * FROM (VALUES
      ('expense',  'month', 1,  NULL::int, NULL::date),
      ('expense',  'month', 1,  -1,        NULL),
      ('expense',  'month', 3,  15,        NULL),
      ('expense',  'week',  2,  NULL,      NULL),
      ('expense',  'year',  1,  NULL,      NULL),
      ('expense',  'month', 1,  28,        DATE '2031-08-10'),
      ('income',   'month', 1,  1,         NULL),
      ('income',   'week',  1,  NULL,      DATE '2031-05-31'),
      ('transfer', 'month', 1,  -2,        NULL),
      ('transfer', 'month', 2,  10,        DATE '2031-09-30'),
      ('transfer', 'week',  4,  NULL,      NULL)) x(kind, unit, intv, dom, last_day) LOOP
    BEGIN
      IF r.kind = 'transfer' THEN
        v_res := finance.fn_create_recurring_transfer(jsonb_build_object('name','__prop_cvp_p2__','from_account_id',v_giro,'to_account_id',v_pot,
          'amount',75.5,'schedule_unit',r.unit,'schedule_interval',r.intv,'first_payment_date','2031-01-31')
          || CASE WHEN r.dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', r.dom) END
          || CASE WHEN r.last_day IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('valid_to', r.last_day) END);
      ELSE
        v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__prop_cvp_p2__','account_id',v_giro,'direction',r.kind,
          'amount',75.5,'schedule_unit',r.unit,'schedule_interval',r.intv,'first_payment_date','2031-01-31')
          || CASE WHEN r.dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', r.dom) END
          || CASE WHEN r.last_day IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('valid_to', r.last_day) END);
      END IF;
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL P2 setup %: %', r, v_res; END IF;
      v_rp := (v_res->>'recurring_payment_id')::int;

      -- P2: alle Sichten gleich; Vorzeichen nach Richtung
      v_before := pg_temp.sig_upcoming(ARRAY[v_rp], c_from, c_until);
      IF v_before = '' THEN RAISE EXCEPTION 'FAIL P2 %: keine Termine', r; END IF;
      IF pg_temp.sig_flows(v_giro, c_from, c_until) <> v_before OR pg_temp.sig_projection(v_giro, c_from, c_until) <> v_before
         OR pg_temp.sig_app(v_giro, c_from, c_until) <> v_before THEN
        RAISE EXCEPTION 'FAIL P2 %: Sichten weichen ab. upcoming=% flows=% projection=% app=%', r, v_before,
          pg_temp.sig_flows(v_giro, c_from, c_until), pg_temp.sig_projection(v_giro, c_from, c_until), pg_temp.sig_app(v_giro, c_from, c_until); END IF;
      IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id = v_rp
                   AND u.amount IS DISTINCT FROM CASE WHEN r.kind = 'income' THEN 75.5 ELSE -75.5 END) THEN
        RAISE EXCEPTION 'FAIL P2 %: Vorzeichen/Betrag', r; END IF;
      IF r.last_day IS NOT NULL AND EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(c_from, c_until) u
                                             WHERE u.recurring_payment_id = v_rp AND u.due_date > r.last_day) THEN
        RAISE EXCEPTION 'FAIL P2 %: Termin nach dem letzten gueltigen Tag', r; END IF;
      IF r.kind = 'transfer' THEN
        IF pg_temp.sig_flows(v_pot, c_from, c_until) <> replace(v_before, '=-', '=')
           OR pg_temp.sig_app(v_pot, c_from, c_until) <> replace(v_before, '=-', '=')
           OR pg_temp.sig_projection(v_pot, c_from, c_until) <> replace(v_before, '=-', '=') THEN
          RAISE EXCEPTION 'FAIL P2 %: Ziel-Seite des Uebertrags ist nicht das Spiegelbild der Quelle', r; END IF;
      ELSIF pg_temp.sig_flows(v_pot, c_from, c_until) <> '' THEN
        RAISE EXCEPTION 'FAIL P2 %: fremdes Konto zeigt die Zahlung', r;
      END IF;
      v_n_read := v_n_read + 1;

      -- P3: zweiten Termin buchen -> genau dieser fehlt, Endstand gleich; stornieren -> wie vorher
      SELECT u.due_date, u.amount INTO o FROM finance.fn_upcoming_payments(c_from, c_until) u
        WHERE u.recurring_payment_id = v_rp ORDER BY u.due_date OFFSET 1 LIMIT 1;
      v_end0 := pg_temp.end_balance(v_giro, c_from, c_until);
      SELECT count(*) INTO v_cnt FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id = v_rp;
      v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',o.due_date));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL P3 %: Buchung abgelehnt %', r, v_res; END IF;
      v_tx := COALESCE((v_res->>'transaction_id')::int, (v_res->>'debit_tx_id')::int);
      IF (SELECT count(*) FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id = v_rp) <> v_cnt - 1
         OR EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id = v_rp AND u.due_date = o.due_date) THEN
        RAISE EXCEPTION 'FAIL P3 %: nach dem Buchen fehlt nicht genau der gebuchte Termin %', r, o.due_date; END IF;
      v_end1 := pg_temp.end_balance(v_giro, c_from, c_until);
      IF v_end1 IS DISTINCT FROM v_end0 THEN
        RAISE EXCEPTION 'FAIL P3 %: Endstand der Kontovorschau vor dem Buchen % nachher %', r, v_end0, v_end1; END IF;
      IF pg_temp.sig_flows(v_giro, c_from, c_until) <> pg_temp.sig_upcoming(ARRAY[v_rp], c_from, c_until) THEN
        RAISE EXCEPTION 'FAIL P3 %: Sichten nach dem Buchen ungleich', r; END IF;
      v_res := finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL P3 %: Storno abgelehnt %', r, v_res; END IF;
      IF pg_temp.sig_upcoming(ARRAY[v_rp], c_from, c_until) <> v_before OR pg_temp.end_balance(v_giro, c_from, c_until) IS DISTINCT FROM v_end0 THEN
        RAISE EXCEPTION 'FAIL P3 %: nach dem Storno nicht der Ausgangszustand', r; END IF;
      -- Ueberspringen nimmt genau diesen Termin heraus
      PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',o.due_date));
      IF (SELECT count(*) FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id = v_rp) <> v_cnt - 1
         OR pg_temp.sig_flows(v_giro, c_from, c_until) <> pg_temp.sig_upcoming(ARRAY[v_rp], c_from, c_until)
         OR pg_temp.end_balance(v_giro, c_from, c_until) IS DISTINCT FROM v_end0 - o.amount THEN
        RAISE EXCEPTION 'FAIL P3 %: Ueberspringen nimmt nicht genau einen Termin samt Betrag heraus', r; END IF;
      v_n_book := v_n_book + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;

  -- P4: pausieren / fortsetzen, einzelnes Glied und Kette aus zwei Gliedern (Betrags-Wechsel in der Zukunft)
  FOREACH v_dom IN ARRAY v_doms LOOP
    FOREACH v_bounded IN ARRAY ARRAY[false, true] LOOP
      BEGIN
        v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__prop_cvp_p4__','account_id',v_giro,
          'direction','expense','amount',100,'schedule_unit','month','first_payment_date','2031-01-15')
          || CASE WHEN v_dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', v_dom) END);
        v_rp := (v_res->>'recurring_payment_id')::int;
        v_new := v_rp;
        IF v_bounded THEN   -- hier: Kette aus zwei Gliedern
          v_new := (finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',130,'valid_from','2031-06-10'))->>'recurring_payment_id')::int;
        END IF;
        v_before := pg_temp.sig_flows(v_giro, c_from, c_until);
        v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_new,'status','paused'));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL P4: Pausieren abgelehnt %', v_res; END IF;
        IF pg_temp.sig_flows(v_giro, c_from, c_until) <> '' THEN
          RAISE EXCEPTION 'FAIL P4 [dom=% kette=%]: pausierte Zahlung steht noch in der Vorschau: %', v_dom, v_bounded, pg_temp.sig_flows(v_giro, c_from, c_until); END IF;
        v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'status','active'));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL P4: Fortsetzen abgelehnt %', v_res; END IF;
        v_after := pg_temp.sig_flows(v_giro, c_from, c_until);
        IF v_after <> v_before THEN
          RAISE EXCEPTION 'FAIL P4 [dom=% kette=%]: nach Pausieren+Fortsetzen % statt %', v_dom, v_bounded, v_after, v_before; END IF;
        v_n_pause := v_n_pause + 1;
        RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
      EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
      END;
    END LOOP;
  END LOOP;

  -- P5: "startet am" der Views = erster Termin der Vorschau, auch wenn der genannte Geltungsbeginn kein Termin ist
  FOREACH v_dom IN ARRAY v_doms LOOP
    FOR v_k IN 0..40 BY 8 LOOP
      BEGIN
        v_eff := DATE '2031-03-01' + v_k;   -- genannter Geltungsbeginn
        v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__prop_cvp_p5__','account_id',v_giro,
          'direction','expense','amount',100,'schedule_unit','month','first_payment_date',v_eff,'valid_from',v_eff)
          || CASE WHEN v_dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', v_dom) END);
        v_rp := (v_res->>'recurring_payment_id')::int;
        SELECT min(u.due_date) INTO v_eff2 FROM finance.fn_upcoming_payments(c_from, c_until) u WHERE u.recurring_payment_id = v_rp;
        IF (SELECT starts_on FROM finance.upcoming_recurring_payments WHERE id = v_rp) IS DISTINCT FROM v_eff2
           OR finance.fn_recurring_first_due(v_rp) IS DISTINCT FROM v_eff2 THEN
          RAISE EXCEPTION 'FAIL P5 [dom=% geltung ab %]: starts_on % / first_due %, erster Termin der Vorschau %', v_dom, v_eff,
            (SELECT starts_on FROM finance.upcoming_recurring_payments WHERE id = v_rp), finance.fn_recurring_first_due(v_rp), v_eff2; END IF;
        v_n_start := v_n_start + 1;
        RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
      EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
      END;
    END LOOP;
  END LOOP;

  -- P5, Geltungsbeginn Monate vor der ersten Abbuchung (Vertragsbeginn im Januar, erste Abbuchung im August)
  BEGIN
    v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__prop_cvp_p5b__','account_id',v_giro,
      'direction','expense','amount',100,'schedule_unit','month','first_payment_date','2031-08-15','valid_from','2031-01-01'));
    v_rp := (v_res->>'recurring_payment_id')::int;
    IF (SELECT starts_on FROM finance.upcoming_recurring_payments WHERE id = v_rp) IS DISTINCT FROM DATE '2031-08-15' THEN
      RAISE EXCEPTION 'FAIL P5 [Geltung ab 2031-01-01, erste Abbuchung 2031-08-15]: starts_on %', (SELECT starts_on FROM finance.upcoming_recurring_payments WHERE id = v_rp); END IF;
    v_n_start := v_n_start + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  RAISE NOTICE 'PASS prop recurring change vs preview [P1 Split: % Faelle (je 2 Wechsel), P2 Sichten: %, P3 Buchen/Storno/Skip: %, P4 Pause/Fortsetzen: %, P5 startet am: %]',
    v_n_split, v_n_read, v_n_book, v_n_pause, v_n_start;
END $$;

ROLLBACK;
