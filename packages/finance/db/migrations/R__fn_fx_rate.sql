-- ============================================================
-- fn_fx_rate (READ, STABLE) -- Wechselkurs fuer jedes Waehrungspaar zum Stichtag
--   Kurs "Einheiten quote je 1 base", abgeleitet aus den EUR-Zeilen von finance.fx_rates ueber die eine Kurs-Suche
--   finance.fn_fx_eur_row: rate = eur_rate(quote) / eur_rate(base). EUR/X ist damit exakt die gespeicherte Zeile,
--   X/EUR ihr Kehrwert, X/Y gekreuzt ueber EUR. Lesepfad fuer Waechter (fn_monitor_acquire_fx_rate) und den Berater
--   (postgres_select unter finance_ro): kein Modell rechnet Kehrwerte oder Kreuzkurse selbst.
--   Eingabe: p_base, p_quote (ISO-Code, Gross-/Kleinschreibung egal), p_as_of (Default heute).
--   Rueckgabe: genau eine Zeile (rate numeric, as_of date); as_of = das aeltere der beiden verwendeten Kurs-Daten
--   (ehrlich fuer Alters-Pruefungen), EUR/EUR -> (1, Stichtag). Fehlt eine Seite -> (NULL, NULL).
--   Tests: tests/db/finance/test_fn_fx_rate.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_fx_rate(
    p_base  text,
    p_quote text,
    p_as_of date DEFAULT current_date
) RETURNS TABLE (rate numeric, as_of date) LANGUAGE sql STABLE AS $$
    SELECT q.rate / NULLIF(b.rate, 0),
           CASE WHEN b.rate IS NOT NULL AND q.rate IS NOT NULL
                THEN COALESCE(LEAST(b.as_of, q.as_of), p_as_of) END
    FROM (SELECT upper(trim(p_base)) AS base, upper(trim(p_quote)) AS quote) k
    LEFT JOIN LATERAL (SELECT e.rate, e.as_of FROM finance.fn_fx_eur_row(k.base::char(3), p_as_of) e) b ON length(k.base) = 3
    LEFT JOIN LATERAL (SELECT e.rate, e.as_of FROM finance.fn_fx_eur_row(k.quote::char(3), p_as_of) e) q ON length(k.quote) = 3;
$$;
