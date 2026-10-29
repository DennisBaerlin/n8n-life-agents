-- ============================================================
-- fn_account_projection (READ, STABLE) -- Tagesreihe des voraussichtlichen Kontostands, der EINE Rechenkern
--   Konsumenten: fn_account_outlook (Kontovorschau bis zum naechsten Geldeingang, mit Alltagsausgaben) und
--   fn_account_funding (Spar-Deckung ueber den Horizont, ohne Alltagsausgaben). Muster Actual Budget „Balance Forecast"
--   (Saldo + geplante Vorkommen inkl. Uebertraege) / Quicken Simplifi „projected balance".
--   Stand(d) = Saldo zum Vortag von p_from (fn_get_balance_as_of) + Buchungen in [p_from, d] + offene
--   Dauerauftrags-Vorkommen in [p_from, d] (finance.fn_upcoming_payments: Quell-Seite = Buchungsbetrag, Kredit-
--   Schlussrate = Abloese) + p_per_day x Tage seit p_from.
--   Ziel-Seite eines Uebertrags = abs(geplanter Betrag) in ZIELwaehrung: gleiche Waehrung roh, sonst ueber den Kurs
--   (fn_to_eur_unrounded, 2 Stellen); fehlt ein Kurs, zaehlt der Quellbetrag roh (wie vor dem Umbau, nie still 0)
--   und fx_gap ist an dem Tag true (fn_account_funding zeigt dann „nicht ermittelbar").
--   Eine Zeile je Tag (auch ohne Fluss); inflow/outflow = Summe der positiven bzw. negativen Fluesse des Tages (nicht
--   verrechnet). Keine Zinsen (P2P/Festgeld) -> eher vorsichtig gerechnet.
--   RUECKGABE: (day, bal, inflow, outflow, fx_gap); unbekanntes Konto -> leer
--   Tests: tests/db/finance/test_fn_account_projection.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_projection(p_account_id int, p_from date, p_until date, p_per_day numeric)
RETURNS TABLE(day date, bal numeric, inflow numeric, outflow numeric, fx_gap boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cur  CHAR(3);
    v_base NUMERIC;
BEGIN
    SELECT a.currency INTO v_cur FROM finance.accounts a WHERE a.id = p_account_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    v_base := COALESCE(finance.fn_get_balance_as_of(p_account_id, p_from - 1), 0);

    RETURN QUERY
    WITH occ AS (
        SELECT u.due_date AS fd,
               CASE WHEN u.account_id = p_account_id THEN u.amount
                    WHEN sa.currency = v_cur THEN abs(u.planned_amount)
                    ELSE round(finance.fn_to_eur_unrounded(abs(u.planned_amount), sa.currency)
                               / NULLIF(finance.fn_to_eur_unrounded(1, v_cur), 0), 2) END AS amt,
               abs(u.planned_amount) AS raw
        FROM finance.fn_upcoming_payments(p_from, p_until) u
        JOIN finance.accounts sa ON sa.id = u.account_id
        WHERE u.account_id = p_account_id OR u.target_account_id = p_account_id
    ), f AS (
        SELECT occ.fd, COALESCE(occ.amt, occ.raw) AS amt, occ.amt IS NULL AS gap FROM occ
        UNION ALL
        SELECT t.transaction_date, t.amount, false FROM finance.transactions t
        WHERE t.account_id = p_account_id AND t.transaction_date BETWEEN p_from AND p_until
    ), g AS (
        SELECT f.fd,
               COALESCE(sum(f.amt) FILTER (WHERE f.amt > 0), 0) AS i,
               COALESCE(sum(f.amt) FILTER (WHERE f.amt < 0), 0) AS o,
               bool_or(f.gap) AS gap
        FROM f GROUP BY f.fd
    )
    SELECT s.d::date,
           v_base + sum(COALESCE(g.i, 0) + COALESCE(g.o, 0)) OVER (ORDER BY s.d)
                  + COALESCE(p_per_day, 0) * (s.d::date - p_from + 1),
           COALESCE(g.i, 0::numeric),
           COALESCE(g.o, 0::numeric),
           COALESCE(g.gap, false)
    FROM generate_series(p_from::timestamp, p_until::timestamp, interval '1 day') AS s(d)
    LEFT JOIN g ON g.fd = s.d::date
    ORDER BY s.d;
END;
$$;
