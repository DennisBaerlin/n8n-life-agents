-- ============================================================
-- fn_interest_rate_segments (READ — taggenaue Satz-Segmente einer Zins-Periode; DB rechnet, nie das LLM)
--   Zerschneidet die Periode [p_period_start, p_period_end) an JEDEM Satzwechsel (account_interest_rates.
--   valid_from STRIKT innerhalb der Periode) und liefert je Teil-Segment (seg_start, seg_end, annual_rate,
--   day_count_convention). Etabliertes Muster (OpenGamma Strata RateAccrualPeriod / deutsche Zinsstaffel):
--   pro Segment der eigene Jahres-Bruchteil, der Aufrufer summiert.
--
--   Satz je Segment = die Rate-Zeile, deren halb-offenes Gueltigkeits-Intervall das GANZE Segment ENTHAELT —
--     RANGE-CONTAINMENT-Join (range @> range) auf EXAKT die daterange-Expression der EXCLUDE-gist-Constraint
--     (Sentinel '9999-12-31', '[)') -> EINE autoritative Tiling-Quelle, kein zweiter GREATEST(valid_from)-Max-
--     Scan. valid_from ist inklusiv (neuer Satz "gilt ab" -> gehoert ins rechte Segment). Da die Zeilen
--     ueberlappungsfrei (EXCLUDE) + lueckenlos historisiert sind (Close-then-Insert), liegt jedes Segment voll
--     in genau einer Zeile. (Range-Containment statt Punkt-`@> seg_start`: eine Luecke zwischen valid_to und
--     dem naechsten valid_from liegt INNERHALB eines Segments — Punkt-Containment auf den seg_start wuerde sie
--     nicht sehen, Range-Containment schon.)
--
--   LUECKEN-Robustheit: ein nicht voll gedecktes Segment (Datenkorruption) faellt hier per INNER JOIN raus;
--     der Aufrufer fn_interest_amount_due faengt das fail-closed ab (Summe der Segment-Tage muss die Periode
--     decken, sonst RAISE) statt still zu unterverzinsen.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_rate_segments(
    p_account_id int, p_period_start date, p_period_end date
) RETURNS TABLE(seg_start date, seg_end date, annual_rate numeric, day_count_convention text)
LANGUAGE sql STABLE AS $$
    WITH bnd AS (
        SELECT p_period_start AS b
        UNION SELECT p_period_end
        UNION SELECT r.valid_from
          FROM finance.account_interest_rates r
         WHERE r.account_id = p_account_id
           AND r.valid_from > p_period_start
           AND r.valid_from < p_period_end
    ),
    seg AS (
        SELECT b AS s, lead(b) OVER (ORDER BY b) AS nxt
          FROM bnd
    ),
    real_seg AS (
        SELECT s, nxt FROM seg WHERE nxt IS NOT NULL   -- letzter Boundary (= period_end) hat kein Folge-Segment
    )
    SELECT rs.s, rs.nxt, r.annual_rate, r.day_count_convention
      FROM real_seg rs
      JOIN finance.account_interest_rates r
        ON r.account_id = p_account_id
       AND daterange(r.valid_from, COALESCE(r.valid_to, '9999-12-31'::date), '[)')
           @> daterange(rs.s, rs.nxt, '[)')
     ORDER BY rs.s;
$$;
