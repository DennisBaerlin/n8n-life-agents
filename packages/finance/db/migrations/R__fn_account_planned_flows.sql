-- ============================================================
-- fn_account_planned_flows (READ, STABLE) -- offene Dauerauftrags-Vorkommen eines Kontos in [p_from, p_until], je Vorkommen
--   die EINE Quelle fuer die Tagesreihe finance.fn_account_projection und die Einzelzeilen der Bruecke auf dem
--   Mini-App-Bildschirm „Zahlungen“ (Transparenz 2026-10-30: dieselben Betraege wie die Reihe, nie nachgerechnet).
--   Quell-Seite = Buchungsbetrag aus finance.fn_upcoming_payments (signiert; Kredit-Schlussrate = Abloese);
--   Ziel-Seite eines Uebertrags = abs(geplanter Betrag) in ZIELwaehrung: gleiche Waehrung roh, sonst ueber den Kurs
--   (fn_to_eur_unrounded, 2 Stellen); fehlt ein Kurs, zaehlt der Quellbetrag roh (nie still 0) und fx_gap ist true.
--   RUECKGABE: (due_date, recurring_payment_id, amount, fx_gap); unbekanntes Konto -> leer
--   Tests: tests/db/finance/test_fn_account_projection.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_planned_flows(p_account_id int, p_from date, p_until date)
RETURNS TABLE(due_date date, recurring_payment_id int, amount numeric, fx_gap boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cur CHAR(3);
BEGIN
    SELECT a.currency INTO v_cur FROM finance.accounts a WHERE a.id = p_account_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    RETURN QUERY
    WITH occ AS (
        SELECT u.due_date AS fd, u.recurring_payment_id AS rp,
               CASE WHEN u.account_id = p_account_id THEN u.amount
                    WHEN sa.currency = v_cur THEN abs(u.planned_amount)
                    ELSE round(finance.fn_to_eur_unrounded(abs(u.planned_amount), sa.currency)
                               / NULLIF(finance.fn_to_eur_unrounded(1, v_cur), 0), 2) END AS amt,
               abs(u.planned_amount) AS raw
        FROM finance.fn_upcoming_payments(p_from, p_until) u
        JOIN finance.accounts sa ON sa.id = u.account_id
        WHERE u.account_id = p_account_id OR u.target_account_id = p_account_id
    )
    SELECT occ.fd, occ.rp, COALESCE(occ.amt, occ.raw), occ.amt IS NULL FROM occ;
END;
$$;
