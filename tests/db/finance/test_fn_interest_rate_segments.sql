-- tests/db/finance/test_fn_interest_rate_segments.sql
-- WS-Z3: der Satz-Segmenter zerschneidet [period_start, period_end) an jedem valid_from STRIKT innerhalb und
-- ordnet je Segment den deckenden Satz/Konvention per Containment-Join zu (valid_from inklusiv, half-open '[)').
BEGIN;

DO $$
DECLARE
  v_res  JSONB;
  v_acct INT;
  v_cnt  INT;
  v_rate NUMERIC;
  v_conv TEXT;
  v_s    DATE;
  v_e    DATE;
  v_days INT;
BEGIN
  -- Setup: Konto mit drei Rate-Zeilen (verschiedene Konventionen je Zeile).
  SELECT finance.fn_create_account('{"name":"__test_seg__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, day_count_convention, valid_from, valid_to)
  VALUES (v_acct, 4, 1, 'month', '30E/360', '2026-01-01', '2026-01-15'),
         (v_acct, 5, 1, 'month', 'ACT/365', '2026-01-15', '2026-02-10'),
         (v_acct, 6, 1, 'month', '30E/360', '2026-02-10', NULL);

  -- ===== Single-Segment: Periode ohne inneren Satzwechsel -> genau ein Segment, voller Satz/Konvention =====
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_rate_segments(v_acct, '2026-02-10', '2026-03-01');
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [single seg count]: erwartet 1, got %', v_cnt; END IF;
  SELECT seg_start, seg_end, annual_rate, day_count_convention INTO v_s, v_e, v_rate, v_conv
    FROM finance.fn_interest_rate_segments(v_acct, '2026-02-10', '2026-03-01');
  IF v_s <> '2026-02-10' OR v_e <> '2026-03-01' OR v_rate <> 6 OR v_conv <> '30E/360' THEN
    RAISE EXCEPTION 'FAIL [single seg]: erwartet (2026-02-10,2026-03-01,6,30E/360), got (%,%,%,%)', v_s, v_e, v_rate, v_conv; END IF;
  RAISE NOTICE 'PASS [Single-Segment: voller Satz 6%% 30E/360]';

  -- ===== Zwei Segmente: Schnitt am inneren valid_from 2026-01-15; Satz/Konvention je Segment =====
  -- [2026-01-01,2026-02-01): Boundary {01-01, 01-15, 02-01} (02-10 liegt NICHT < 02-01 -> ignoriert).
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_rate_segments(v_acct, '2026-01-01', '2026-02-01');
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [two seg count]: erwartet 2, got %', v_cnt; END IF;
  -- Seg 1: [2026-01-01, 2026-01-15), 4%, 30E/360 (Satz deckt seg_start 2026-01-01)
  SELECT annual_rate, day_count_convention INTO v_rate, v_conv FROM finance.fn_interest_rate_segments(v_acct, '2026-01-01', '2026-02-01') WHERE seg_start = '2026-01-01';
  IF v_rate IS DISTINCT FROM 4 OR v_conv IS DISTINCT FROM '30E/360' THEN RAISE EXCEPTION 'FAIL [seg1]: erwartet 4/30E360, got %/%', v_rate, v_conv; END IF;
  -- Seg 2: [2026-01-15, 2026-02-01), 5%, ACT/365 (valid_from inklusiv -> 2026-01-15 gehoert ins rechte Segment)
  SELECT seg_end, annual_rate, day_count_convention INTO v_e, v_rate, v_conv FROM finance.fn_interest_rate_segments(v_acct, '2026-01-01', '2026-02-01') WHERE seg_start = '2026-01-15';
  IF v_e IS DISTINCT FROM DATE '2026-02-01' OR v_rate IS DISTINCT FROM 5 OR v_conv IS DISTINCT FROM 'ACT/365' THEN
    RAISE EXCEPTION 'FAIL [seg2 valid_from-inklusiv]: erwartet end 2026-02-01, 5, ACT/365, got %, %, %', v_e, v_rate, v_conv; END IF;
  RAISE NOTICE 'PASS [Zwei Segmente: 4%%/30E360 + 5%%/ACT365, valid_from inklusiv]';

  -- ===== Deckung: Segment-Tage tilen die Periode lueckenlos (Roh-Kalendertage = period_end - period_start) =====
  SELECT COALESCE(SUM(seg_end - seg_start), 0) INTO v_days FROM finance.fn_interest_rate_segments(v_acct, '2026-01-01', '2026-02-01');
  IF v_days <> (DATE '2026-02-01' - DATE '2026-01-01') THEN RAISE EXCEPTION 'FAIL [coverage]: Segment-Tage % <> Spanne %', v_days, (DATE '2026-02-01' - DATE '2026-01-01'); END IF;
  RAISE NOTICE 'PASS [Deckung: Segment-Tage = Perioden-Spanne (lueckenlos)]';

  -- ===== period_start == valid_from: kein Extra-Boundary (nicht STRIKT innerhalb), aber gedeckt =====
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_rate_segments(v_acct, '2026-01-15', '2026-02-01');
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [pstart==valid_from]: erwartet 1 Segment, got %', v_cnt; END IF;
  SELECT annual_rate INTO v_rate FROM finance.fn_interest_rate_segments(v_acct, '2026-01-15', '2026-02-01');
  IF v_rate IS DISTINCT FROM 5 THEN RAISE EXCEPTION 'FAIL [pstart==valid_from]: erwartet 5%%, got %', v_rate; END IF;
  RAISE NOTICE 'PASS [period_start == valid_from -> ein Segment, deckender Satz 5%%]';
END $$;

ROLLBACK;
