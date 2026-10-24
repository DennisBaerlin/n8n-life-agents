-- tests/db/finance/test_fn_interest_period_start.sql
-- WP-2: die geteilte Tiling-Quelle fn_interest_period_start (dom-aware period_start). Beweist:
--   (1) direkte Werte: dom=-1 rekonstruiert den Monatsletzten der Vorperiode (behebt den Overlap), erste
--       Periode clamped auf den Anker; fester dom / NULL-dom(Monatsend-Anker) / day / year korrekt,
--   (2) Kachel-Invariante + 365-Tage-Partition: 12 dom=-1-Monatsperioden eines Nicht-Schaltjahres kacheln
--       lueckenlos (period_start(k) == period_end(k-1)) und decken EXAKT 365 Tage (kein Overlap, keine Luecke).
BEGIN;
DO $$
DECLARE r RECORD; v_prev_end DATE; v_days INT; v_ps DATE;
BEGIN
  -- ===== (1) direkte Werte =====
  IF finance.fn_interest_period_start(DATE '2026-01-15', DATE '2026-02-28', 1, 'month', -1) <> DATE '2026-01-31' THEN
    RAISE EXCEPTION 'FAIL [dom=-1]: period_start(Feb28) erwartet 2026-01-31, got %',
      finance.fn_interest_period_start(DATE '2026-01-15', DATE '2026-02-28', 1, 'month', -1); END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-15', DATE '2026-01-31', 1, 'month', -1) <> DATE '2026-01-15' THEN
    RAISE EXCEPTION 'FAIL [dom=-1 clamp]: erste Periode erwartet Anker 2026-01-15'; END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-10', DATE '2026-02-15', 1, 'month', 15) <> DATE '2026-01-15' THEN
    RAISE EXCEPTION 'FAIL [fixed dom=15]: erwartet 2026-01-15'; END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-31', DATE '2026-02-28', 1, 'month', NULL) <> DATE '2026-01-31' THEN
    RAISE EXCEPTION 'FAIL [NULL-dom Anker-31]: erwartet 2026-01-31 (kein Overlap trotz Monatsend-Anker)'; END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-01', DATE '2026-01-08', 7, 'day', NULL) <> DATE '2026-01-01' THEN
    RAISE EXCEPTION 'FAIL [day n=7]: erwartet 2026-01-01'; END IF;
  IF finance.fn_interest_period_start(DATE '2020-06-15', DATE '2026-06-15', 1, 'year', NULL) <> DATE '2025-06-15' THEN
    RAISE EXCEPTION 'FAIL [year]: erwartet 2025-06-15'; END IF;
  RAISE NOTICE 'PASS [(1) fn_interest_period_start: dom=-1/fixed/NULL-Anker31/day/year korrekt]';

  -- ===== (2) Kachel-Invariante + 365-Tage-Partition (dom=-1, Anker 2024-12-31, ganzes Nicht-Schaltjahr 2025) =====
  v_prev_end := DATE '2024-12-31';   -- der Anker = boundary(0)
  v_days := 0;
  FOR r IN
    -- boundary(1)..boundary(12) = Monatsletzte Jan..Dez 2025 (dom=-1-Enumeration wie in fn_interest_due_open)
    SELECT (date_trunc('month', DATE '2024-12-31') + (g || ' months')::interval
            + interval '1 month' - interval '1 day')::date AS pe
    FROM generate_series(1, 12) g
    ORDER BY g
  LOOP
    v_ps := finance.fn_interest_period_start(DATE '2024-12-31', r.pe, 1, 'month', -1);
    IF v_ps <> v_prev_end THEN
      RAISE EXCEPTION 'FAIL [Kachel]: period_start % != vorheriges period_end % (pe=%)', v_ps, v_prev_end, r.pe; END IF;
    v_days := v_days + (r.pe - v_ps);
    v_prev_end := r.pe;
  END LOOP;
  IF v_prev_end <> DATE '2025-12-31' THEN
    RAISE EXCEPTION 'FAIL [Partition]: letztes period_end erwartet 2025-12-31, got %', v_prev_end; END IF;
  IF v_days <> 365 THEN
    RAISE EXCEPTION 'FAIL [Partition]: Summe Deckungstage erwartet EXAKT 365 (kein Overlap/keine Luecke), got %', v_days; END IF;
  RAISE NOTICE 'PASS [(2) dom=-1 Kachel-Invariante + 365-Tage-Partition]';

  -- ===== (3) Kalender-Raster bei dom=-1 (Live-Befund 2026-10-24): Quartals-/Halbjahres-/Jahresende = Kalender-Ende =====
  -- vierteljaehrlich, Start 24.10.: erste Teilperiode 24.10.-31.12., dann 31.12.-31.03. (vorher am Anker: 31.10./31.01.)
  IF finance.fn_interest_period_start(DATE '2026-10-24', DATE '2026-12-31', 3, 'month', -1) <> DATE '2026-10-24' THEN
    RAISE EXCEPTION 'FAIL [Quartal Teilperiode]: erwartet Anker 2026-10-24, got %',
      finance.fn_interest_period_start(DATE '2026-10-24', DATE '2026-12-31', 3, 'month', -1); END IF;
  IF finance.fn_interest_period_start(DATE '2026-10-24', DATE '2027-03-31', 3, 'month', -1) <> DATE '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL [Quartal]: period_start(31.03.) erwartet 2026-12-31, got %',
      finance.fn_interest_period_start(DATE '2026-10-24', DATE '2027-03-31', 3, 'month', -1); END IF;
  IF finance.fn_interest_period_start(DATE '2026-02-10', DATE '2026-12-31', 6, 'month', -1) <> DATE '2026-06-30' THEN
    RAISE EXCEPTION 'FAIL [Halbjahr]: erwartet 2026-06-30'; END IF;
  IF finance.fn_interest_period_start(DATE '2026-10-24', DATE '2027-12-31', 1, 'year', -1) <> DATE '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL [Jahresende]: erwartet 2026-12-31'; END IF;
  IF finance.fn_interest_period_start(DATE '2026-10-24', DATE '2029-12-31', 2, 'year', -1) <> DATE '2027-12-31' THEN
    RAISE EXCEPTION 'FAIL [alle 2 Jahre Jahresende]: erwartet 2027-12-31'; END IF;
  -- Schaltjahr: Quartal ueber den 29.02.; Monatsende im Februar eines Schaltjahres
  IF finance.fn_interest_period_start(DATE '2027-11-05', DATE '2028-03-31', 3, 'month', -1) <> DATE '2027-12-31' THEN
    RAISE EXCEPTION 'FAIL [Quartal Schaltjahr]: erwartet 2027-12-31'; END IF;
  IF finance.fn_interest_period_start(DATE '2028-01-10', DATE '2028-03-31', 1, 'month', -1) <> DATE '2028-02-29' THEN
    RAISE EXCEPTION 'FAIL [Monatsende Schaltjahr]: erwartet 2028-02-29'; END IF;
  -- Altzeile: dom=-1 mit nicht-kalendertauglichem Intervall (5) bleibt am Anker-Monat (unveraendert)
  IF finance.fn_interest_period_start(DATE '2026-01-15', DATE '2026-06-30', 5, 'month', -1) <> DATE '2026-01-31' THEN
    RAISE EXCEPTION 'FAIL [n=5 Anker-Raster]: erwartet 2026-01-31'; END IF;
  -- Kachel-Invariante Quartal: Anker auf dem Raster (31.12.2026) -> vier Quartale 2027 = exakt 365 Tage
  v_prev_end := DATE '2026-12-31';
  v_days := 0;
  FOR r IN SELECT unnest(ARRAY[DATE '2027-03-31', DATE '2027-06-30', DATE '2027-09-30', DATE '2027-12-31']) AS pe LOOP
    v_ps := finance.fn_interest_period_start(DATE '2026-12-31', r.pe, 3, 'month', -1);
    IF v_ps <> v_prev_end THEN
      RAISE EXCEPTION 'FAIL [Kachel Quartal]: period_start % != vorheriges period_end % (pe=%)', v_ps, v_prev_end, r.pe; END IF;
    v_days := v_days + (r.pe - v_ps);
    v_prev_end := r.pe;
  END LOOP;
  IF v_days <> 365 THEN RAISE EXCEPTION 'FAIL [Partition Quartal]: erwartet 365, got %', v_days; END IF;
  RAISE NOTICE 'PASS [(3) dom=-1 kalendergerecht: Quartal/Halbjahr/Jahr, Schaltjahr, n=5 Altraster, Quartals-Kachel]';

  -- ===== (4) Raster-Helfer: naechstes Periodenende + Gutschrift-Datum (Karte "Erste Gutschrift") =====
  IF finance.fn_interest_next_period_end(DATE '2026-10-24', DATE '2026-10-24', 3, 'month', -1) <> DATE '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL [next Quartal]'; END IF;
  IF finance.fn_interest_next_period_end(DATE '2026-12-31', DATE '2026-12-31', 3, 'month', -1) <> DATE '2027-03-31' THEN
    RAISE EXCEPTION 'FAIL [next Anker auf Raster ist keine Gutschrift]'; END IF;
  IF finance.fn_interest_next_period_end(DATE '2026-10-24', DATE '2026-10-24', 1, 'year', NULL) <> DATE '2027-10-24' THEN
    RAISE EXCEPTION 'FAIL [next Jahrestag]'; END IF;
  IF finance.fn_interest_next_period_end(DATE '2026-10-24', DATE '2026-11-10', 1, 'month', -1) <> DATE '2026-11-30' THEN
    RAISE EXCEPTION 'FAIL [next nach Satzwechsel im Regime]'; END IF;
  IF finance.fn_interest_value_date(DATE '2026-10-31', 1::smallint) <> DATE '2026-11-01'
     OR finance.fn_interest_value_date(DATE '2026-12-31', NULL) <> DATE '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL [value_date Arrears/Default]'; END IF;
  RAISE NOTICE 'PASS [(4) fn_interest_next_period_end + fn_interest_value_date]';
END $$;
ROLLBACK;
