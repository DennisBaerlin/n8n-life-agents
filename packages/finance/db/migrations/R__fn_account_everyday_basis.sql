-- ============================================================
-- fn_account_everyday_basis (READ, STABLE) -- Grundlage der geschaetzten Alltagsausgaben eines Kontos, je Kontoauszug
--   Die EINE Adresse der Auswahl-Regel (Transparenz 2026-10-30, Live-Befund): der FRUEHESTE Auszug eines Kontos (Rang
--   nach period_end, nicht prev_last_reconciled_at IS NULL — ein Chat-Abgleich davor setzt das Feld) entsteht meist,
--   bevor die Dauerauftraege angelegt sind („Import zuerst“): Gehalt und Uebertraege bleiben ungematcht und landen im
--   Alltag. Er zaehlt deshalb nicht, sobald ein spaeterer Auszug existiert (reason 'earliest'); gibt es nur ihn, zaehlt
--   er (Konsument markiert provisional). Gezaehlt werden die juengsten 3 uebrigen Auszuege; aeltere entfallen.
--   days = Tage NACH dem damaligen Schnitt (period_end - GREATEST(period_start - 1, prev_last_reconciled_at,
--   opening_balance_date)); unmatched_* zaehlt nur Zeilen danach (Schnitt wie fn_statement_prepare).
--   per_day = round(unmatched_out / days, 2) (nur Abgaenge) — Anzeige je Auszug (Mini-App-Details).
--   Konsumenten: fn_account_everyday_per_day (Summe der gezaehlten), fn_app_screen_payments (Details-Zeilen).
--   RUECKGABE: (period_start, period_end, days, unmatched_out, unmatched_in, per_day, counted, reason), juengster zuerst,
--   hoechstens die 3 gezaehlten + der fruehste (nur solange er ohne die Regel im Fenster laege); ohne Auszug leer.
--   Tests: tests/db/finance/test_fn_account_everyday_per_day.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_everyday_basis(p_account_id int)
RETURNS TABLE(period_start date, period_end date, days int, unmatched_out numeric, unmatched_in numeric,
              per_day numeric, counted boolean, reason text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_open DATE;
BEGIN
    SELECT a.opening_balance_date INTO v_open FROM finance.accounts a WHERE a.id = p_account_id;
    RETURN QUERY
    WITH s AS (
        SELECT b.period_start AS ps, b.period_end AS pe,
               (b.period_end - GREATEST(b.period_start - 1, b.prev_last_reconciled_at, v_open))::int AS d,
               b.unmatched_out AS uo, b.unmatched_in AS ui,
               (row_number() OVER (ORDER BY b.period_end, b.id) = 1 AND count(*) OVER () > 1) AS earliest
        FROM finance.bank_statements b
        WHERE b.account_id = p_account_id
    ), c AS (
        SELECT s.*, row_number() OVER (PARTITION BY s.earliest ORDER BY s.pe DESC) AS rk
        FROM s
    )
    SELECT c.ps, c.pe, c.d, c.uo, c.ui,
           round(COALESCE(c.uo / NULLIF(c.d, 0), 0), 2),
           NOT c.earliest,
           CASE WHEN c.earliest THEN 'earliest' END
    FROM c
    -- der fruehste erscheint nur, solange er ohne die Regel im Fenster laege (sonst waere er ohnehin zu alt)
    WHERE (NOT c.earliest AND c.rk <= 3)
       OR (c.earliest AND (SELECT count(*) FROM s s2 WHERE NOT s2.earliest) < 3)
    ORDER BY c.pe DESC;
END;
$$;
