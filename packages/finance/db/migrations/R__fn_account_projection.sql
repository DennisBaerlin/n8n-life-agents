-- ============================================================
-- fn_account_projection (READ, STABLE) -- Tagesreihe des voraussichtlichen Kontostands, der EINE Rechenkern
--   Konsumenten: fn_account_outlook (Kontovorschau bis zum naechsten Geldeingang, mit Alltagsausgaben) und
--   fn_account_funding (Spar-Deckung ueber den Horizont, ohne Alltagsausgaben). Muster Actual Budget „Balance Forecast"
--   (Saldo + geplante Vorkommen inkl. Uebertraege) / Quicken Simplifi „projected balance".
--   Stand(d) = Saldo zum Vortag von p_from (fn_get_balance_as_of) + Buchungen in [p_from, d] + offene
--   Dauerauftrags-Vorkommen in [p_from, d] (finance.fn_account_planned_flows: Quell-Seite = Buchungsbetrag, Kredit-
--   Schlussrate = Abloese, Ziel-Seite in Zielwaehrung, ohne Kurs Rohbetrag + fx_gap) + p_per_day x Tage seit p_from.
--   Eine Zeile je Tag (auch ohne Fluss); inflow/outflow = Summe der positiven bzw. negativen Fluesse des Tages (nicht
--   verrechnet). Fuer die Bruecke der Kontovorschau (Transparenz 2026-10-30) getrennt: booked = Buchungen des Tages,
--   planned_in / planned_out = positive / negative Vorkommen; inflow + outflow = booked + planned_in + planned_out.
--   Keine Zinsen (P2P/Festgeld) -> eher vorsichtig gerechnet.
--   RUECKGABE: (day, bal, inflow, outflow, fx_gap, booked, planned_in, planned_out); unbekanntes Konto -> leer
--   Rueckgabetyp geaendert 2026-10-30 -> DROP vor CREATE (Konsumenten sind plpgsql, keine View haengt daran).
--   Tests: tests/db/finance/test_fn_account_projection.sql
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_account_projection(int, date, date, numeric);
CREATE FUNCTION finance.fn_account_projection(p_account_id int, p_from date, p_until date, p_per_day numeric)
RETURNS TABLE(day date, bal numeric, inflow numeric, outflow numeric, fx_gap boolean,
              booked numeric, planned_in numeric, planned_out numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base NUMERIC;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM finance.accounts a WHERE a.id = p_account_id) THEN
        RETURN;
    END IF;
    v_base := COALESCE(finance.fn_get_balance_as_of(p_account_id, p_from - 1), 0);

    RETURN QUERY
    WITH f AS (
        SELECT pf.due_date AS fd, pf.amount AS amt, pf.fx_gap AS gap, true AS planned
        FROM finance.fn_account_planned_flows(p_account_id, p_from, p_until) pf
        UNION ALL
        SELECT t.transaction_date, t.amount, false, false FROM finance.transactions t
        WHERE t.account_id = p_account_id AND t.transaction_date BETWEEN p_from AND p_until
    ), g AS (
        SELECT f.fd,
               COALESCE(sum(f.amt) FILTER (WHERE f.amt > 0), 0) AS i,
               COALESCE(sum(f.amt) FILTER (WHERE f.amt < 0), 0) AS o,
               COALESCE(sum(f.amt) FILTER (WHERE NOT f.planned), 0) AS bk,
               COALESCE(sum(f.amt) FILTER (WHERE f.planned AND f.amt > 0), 0) AS pi,
               COALESCE(sum(f.amt) FILTER (WHERE f.planned AND f.amt < 0), 0) AS po,
               bool_or(f.gap) AS gap
        FROM f GROUP BY f.fd
    )
    SELECT s.d::date,
           v_base + sum(COALESCE(g.i, 0) + COALESCE(g.o, 0)) OVER (ORDER BY s.d)
                  + COALESCE(p_per_day, 0) * (s.d::date - p_from + 1),
           COALESCE(g.i, 0::numeric),
           COALESCE(g.o, 0::numeric),
           COALESCE(g.gap, false),
           COALESCE(g.bk, 0::numeric),
           COALESCE(g.pi, 0::numeric),
           COALESCE(g.po, 0::numeric)
    FROM generate_series(p_from::timestamp, p_until::timestamp, interval '1 day') AS s(d)
    LEFT JOIN g ON g.fd = s.d::date
    ORDER BY s.d;
END;
$$;
