-- tests/db/finance/test_prop_schedule_raster.sql
-- Eigenschafts-Test des einen Faelligkeitsrasters finance.fn_schedule_occurrences ueber viele Kombinationen
-- (Anker x Einheit x Intervall x Monatstag bzw. feste Monatstage). Jede lesende Sicht (Erinnerung, Kontovorschau,
-- Restschuld, Sparziel-Rate) zaehlt Termine aus diesem Raster; ein Termin, der hier doppelt oder gar nicht
-- erscheint, verfaelscht alle zugleich.
--   E1 streng aufsteigend, kein Termin doppelt, keiner vor dem Anker oder ausserhalb des Fensters
--   E2 Fenster-Additivitaet: Termine[a,c] = Termine[a,b] + Termine[b+1,c] fuer jeden Schnitt b
--      (Grundlage des Validity-Splits: alte Zeile bis Stichtag-1, neue ab Stichtag, bei gleichem Raster geht nichts verloren)
--   E3 Monatsraster mit festem Tag: je Monat ab dem ersten Termin genau ein Termin im Abstand des Intervalls,
--      -1 = Monatsletzter, -2 = vorletzter Tag (auch Februar / Schaltjahr)
--   E4 fn_schedule_first_occurrence = kleinster Rastertermin ab dem Anker
BEGIN;

DO $$
DECLARE
  v_anchors DATE[] := ARRAY['2033-03-01','2033-03-15','2033-03-28','2033-01-29','2033-01-30','2033-01-31',
                            '2033-02-28','2036-02-28','2036-02-29','2033-04-30','2033-12-31','2036-03-01']::date[];
  v_doms    INT[]  := ARRAY[NULL,1,2,14,15,27,28,-1,-2];
  v_ints    INT[]  := ARRAY[1,3,12];
  v_daysets TEXT[] := ARRAY['{2,9,16,23}','{1,15}','{14,28}'];
  v_units   TEXT[] := ARRAY['day','week','year'];
  v_a DATE; v_dom INT; v_int INT; v_u TEXT; v_ds TEXT; v_cut INT;
  v_all DATE[]; v_l DATE[]; v_r DATE[]; v_b DATE; v_until DATE; v_first DATE;
  v_n INT := 0; v_i INT; v_exp DATE;
BEGIN
  -- Monatsraster: Einzeltag
  FOREACH v_a IN ARRAY v_anchors LOOP
    FOREACH v_dom IN ARRAY v_doms LOOP
      FOREACH v_int IN ARRAY v_ints LOOP
        v_until := (v_a + interval '3 years' + interval '17 days')::date;
        SELECT array_agg(d) INTO v_all FROM finance.fn_schedule_occurrences(v_a, v_int, 'month', v_dom::smallint, NULL, v_a - 40, v_until) d;
        v_n := v_n + 1;
        IF v_all IS NULL THEN
          RAISE EXCEPTION 'FAIL E1 [month a=% dom=% n=%]: kein Termin in 3 Jahren', v_a, v_dom, v_int; END IF;
        -- E1
        IF v_all <> ARRAY(SELECT DISTINCT x FROM unnest(v_all) x ORDER BY x) OR v_all[1] < v_a OR v_all[cardinality(v_all)] > v_until THEN
          RAISE EXCEPTION 'FAIL E1 [month a=% dom=% n=%]: nicht streng aufsteigend / ausserhalb: %', v_a, v_dom, v_int, v_all; END IF;
        -- E3: Folge-Termine im Monatsabstand des Intervalls, Tag wie verlangt
        FOR v_i IN 1..cardinality(v_all) LOOP
          v_exp := CASE
            WHEN v_dom = -1 THEN (date_trunc('month', v_all[1]) + make_interval(months => (v_i - 1) * v_int + 1) - interval '1 day')::date
            WHEN v_dom = -2 THEN (date_trunc('month', v_all[1]) + make_interval(months => (v_i - 1) * v_int + 1) - interval '2 days')::date
            WHEN v_dom IS NULL THEN (v_a + make_interval(months => (v_i - 1) * v_int))::date
            ELSE (date_trunc('month', v_all[1]) + make_interval(months => (v_i - 1) * v_int, days => v_dom - 1))::date END;
          IF v_all[v_i] IS DISTINCT FROM v_exp THEN
            RAISE EXCEPTION 'FAIL E3 [month a=% dom=% n=%]: Termin % ist %, erwartet %', v_a, v_dom, v_int, v_i, v_all[v_i], v_exp; END IF;
        END LOOP;
        -- erster Termin hoechstens ein Intervall nach dem Anker (+3 Tage: 28.02. mit vorletztem Tag -> 30.03.)
        IF v_all[1] > (v_a + make_interval(months => v_int))::date + 3 THEN
          RAISE EXCEPTION 'FAIL E3 [month a=% dom=% n=%]: erster Termin % mehr als ein Intervall nach dem Anker', v_a, v_dom, v_int, v_all[1]; END IF;
        -- E4
        v_first := finance.fn_schedule_first_occurrence(v_a, v_int, 'month', v_dom::smallint, NULL);
        IF v_first IS DISTINCT FROM v_all[1] THEN
          RAISE EXCEPTION 'FAIL E4 [month a=% dom=% n=%]: first_occurrence=% Raster=%', v_a, v_dom, v_int, v_first, v_all[1]; END IF;
        -- E2: Schnitte im 19-Tage-Takt ueber 13 Monate (trifft Termine, Tage davor/danach und Monatsgrenzen)
        FOR v_cut IN 0..400 BY 19 LOOP
          v_b := v_a + v_cut;
          SELECT array_agg(d) INTO v_l FROM finance.fn_schedule_occurrences(v_a, v_int, 'month', v_dom::smallint, NULL, v_a - 40, v_b) d;
          SELECT array_agg(d) INTO v_r FROM finance.fn_schedule_occurrences(v_a, v_int, 'month', v_dom::smallint, NULL, v_b + 1, v_until) d;
          IF COALESCE(v_l, '{}') || COALESCE(v_r, '{}') <> v_all THEN
            RAISE EXCEPTION 'FAIL E2 [month a=% dom=% n=% schnitt=%]: links % + rechts % <> ganz %', v_a, v_dom, v_int, v_b, v_l, v_r, v_all; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    -- Monatsraster: feste Monatstage (Broker-Kalender)
    FOREACH v_ds IN ARRAY v_daysets LOOP
      v_until := (v_a + interval '2 years')::date;
      SELECT array_agg(d ORDER BY d) INTO v_all FROM finance.fn_schedule_occurrences(v_a, 1, 'month', NULL, v_ds::smallint[], v_a - 40, v_until) d;
      v_n := v_n + 1;
      IF v_all <> ARRAY(SELECT DISTINCT x FROM unnest(v_all) x ORDER BY x) OR v_all[1] < v_a THEN
        RAISE EXCEPTION 'FAIL E1 [days a=% tage=%]: %', v_a, v_ds, v_all; END IF;
      IF EXISTS (SELECT 1 FROM unnest(v_all) x WHERE NOT (EXTRACT(DAY FROM x)::int = ANY (v_ds::int[]))) THEN
        RAISE EXCEPTION 'FAIL E3 [days a=% tage=%]: Termin ausserhalb der festen Tage', v_a, v_ds; END IF;
      -- jeder volle Monat im Fenster traegt genau die Tage der Liste
      IF EXISTS (SELECT 1 FROM generate_series(date_trunc('month', v_a) + interval '1 month', date_trunc('month', v_until) - interval '1 month', interval '1 month') m
                 WHERE (SELECT count(*) FROM unnest(v_all) x WHERE date_trunc('month', x) = m) <> cardinality(v_ds::smallint[])) THEN
        RAISE EXCEPTION 'FAIL E3 [days a=% tage=%]: ein voller Monat traegt nicht alle festen Tage', v_a, v_ds; END IF;
      v_first := finance.fn_schedule_first_occurrence(v_a, 1, 'month', NULL, v_ds::smallint[]);
      IF v_first IS DISTINCT FROM v_all[1] THEN
        RAISE EXCEPTION 'FAIL E4 [days a=% tage=%]: first_occurrence=% Raster=%', v_a, v_ds, v_first, v_all[1]; END IF;
      FOR v_cut IN 0..120 BY 7 LOOP
        v_b := v_a + v_cut;
        SELECT array_agg(d ORDER BY d) INTO v_l FROM finance.fn_schedule_occurrences(v_a, 1, 'month', NULL, v_ds::smallint[], v_a - 40, v_b) d;
        SELECT array_agg(d ORDER BY d) INTO v_r FROM finance.fn_schedule_occurrences(v_a, 1, 'month', NULL, v_ds::smallint[], v_b + 1, v_until) d;
        IF COALESCE(v_l, '{}') || COALESCE(v_r, '{}') <> v_all THEN
          RAISE EXCEPTION 'FAIL E2 [days a=% tage=% schnitt=%]', v_a, v_ds, v_b; END IF;
      END LOOP;
    END LOOP;
    -- Tag / Woche / Jahr: der Anker ist der erste Termin, Abstand = Intervall
    FOREACH v_u IN ARRAY v_units LOOP
      FOREACH v_int IN ARRAY ARRAY[1,2,5] LOOP
        v_until := (v_a + CASE v_u WHEN 'year' THEN interval '12 years' ELSE interval '200 days' END)::date;
        SELECT array_agg(d) INTO v_all FROM finance.fn_schedule_occurrences(v_a, v_int, v_u::finance.schedule_unit, NULL, NULL, v_a - 40, v_until) d;
        v_n := v_n + 1;
        IF v_all[1] IS DISTINCT FROM v_a OR v_all <> ARRAY(SELECT DISTINCT x FROM unnest(v_all) x ORDER BY x) THEN
          RAISE EXCEPTION 'FAIL E1 [% a=% n=%]: %', v_u, v_a, v_int, v_all; END IF;
        FOR v_i IN 1..cardinality(v_all) LOOP
          v_exp := CASE v_u WHEN 'day'  THEN v_a + (v_i - 1) * v_int
                            WHEN 'week' THEN v_a + (v_i - 1) * v_int * 7
                            ELSE (v_a + make_interval(years => (v_i - 1) * v_int))::date END;
          IF v_all[v_i] IS DISTINCT FROM v_exp THEN
            RAISE EXCEPTION 'FAIL E3 [% a=% n=%]: Termin % ist %, erwartet %', v_u, v_a, v_int, v_i, v_all[v_i], v_exp; END IF;
        END LOOP;
        IF finance.fn_schedule_first_occurrence(v_a, v_int, v_u::finance.schedule_unit, NULL, NULL) IS DISTINCT FROM v_a THEN
          RAISE EXCEPTION 'FAIL E4 [% a=% n=%]', v_u, v_a, v_int; END IF;
        FOR v_cut IN 0..180 BY 17 LOOP
          v_b := v_a + v_cut;
          SELECT array_agg(d) INTO v_l FROM finance.fn_schedule_occurrences(v_a, v_int, v_u::finance.schedule_unit, NULL, NULL, v_a - 40, v_b) d;
          SELECT array_agg(d) INTO v_r FROM finance.fn_schedule_occurrences(v_a, v_int, v_u::finance.schedule_unit, NULL, NULL, v_b + 1, v_until) d;
          IF COALESCE(v_l, '{}') || COALESCE(v_r, '{}') <> v_all THEN
            RAISE EXCEPTION 'FAIL E2 [% a=% n=% schnitt=%]', v_u, v_a, v_int, v_b; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'PASS prop schedule raster [% Raster-Kombinationen, E1-E4]', v_n;
END $$;

ROLLBACK;
