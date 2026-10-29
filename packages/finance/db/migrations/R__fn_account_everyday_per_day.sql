-- ============================================================
-- fn_account_everyday_per_day (READ, STABLE) -- geschaetzte Alltagsausgaben je Tag eines Kontos aus seinen Auszuegen
--   Einzelumsaetze werden nicht gespeichert -> Schaetzung aus den letzten 3 Auszuegen je neu abgeglichenem Tag
--   (period_end - damaliger Schnitt), gerundet auf 2 Stellen; ohne Auszug 0.
--   per_day     = Summe unmatched_out / Tage (nur Abgaenge, vorsichtig: Kontovorschau bis zum naechsten Geldeingang)
--   per_day_net = (unmatched_out + unmatched_in) / Tage, hoechstens 0 (Spar-Deckung ueber 24 Monate: ohne die nicht
--                 zugeordneten Eingaenge faerbte die lineare Hochrechnung jedes Konto rot)
--   Nenner = die Tage NACH dem damaligen Schnitt (unmatched_* zaehlt nur Zeilen danach; ueberlappende Auszuege
--   wuerden mit der vollen Zeitraumlaenge zu niedrig geschaetzt). Schnitt wie fn_statement_prepare.
--   Aus fn_account_outlook herausgezogen (Rechenkern-Umbau 2026-10-29); Konsumenten: fn_account_outlook (per_day),
--   fn_account_funding (per_day_net).
--   RUECKGABE: (per_day <= 0, per_day_net <= 0, has_history)
--   Tests: tests/db/finance/test_fn_account_everyday_per_day.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_everyday_per_day(p_account_id int)
RETURNS TABLE(per_day numeric, per_day_net numeric, has_history boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_open DATE;
    v_out  NUMERIC;
    v_in   NUMERIC;
    v_days NUMERIC;
    v_hist BOOLEAN;
BEGIN
    SELECT a.opening_balance_date INTO v_open FROM finance.accounts a WHERE a.id = p_account_id;
    SELECT sum(b.unmatched_out), sum(b.unmatched_in),
           sum(b.period_end - GREATEST(b.period_start - 1, b.prev_last_reconciled_at, v_open)),
           count(*) > 0
    INTO v_out, v_in, v_days, v_hist
    FROM (SELECT s.* FROM finance.bank_statements s WHERE s.account_id = p_account_id ORDER BY s.period_end DESC LIMIT 3) b;
    per_day     := round(COALESCE(v_out / NULLIF(v_days, 0), 0), 2);
    per_day_net := LEAST(round(COALESCE((COALESCE(v_out, 0) + COALESCE(v_in, 0)) / NULLIF(v_days, 0), 0), 2), 0);
    has_history := COALESCE(v_hist, false);
    RETURN NEXT;
END;
$$;
