-- ============================================================
-- fn_household_everyday_month (READ, STABLE) -- geschaetzte Alltagsausgaben des Haushalts je Monat in EUR
--   Die eine Adresse fuer „Alltag“ in Fluss-Rechnungen (einrechnen statt nur kennzeichnen): die regelmaessigen
--   Zahlungen (monthly_cashflow_summary) kennen Einkauf/Karte/Bargeld nicht, ohne Alltag wirkten „bleibt frei“,
--   Notreserve-Ziel und Runway zu rosig. Quelle = finance.account_everyday_spending (Schaetzung je
--   Geld-Konto aus den Kontoauszuegen, fn_account_everyday_per_day), Eltern-Blick wie fn_liquidity_snapshot: aktive
--   cash-Konten ohne kind-besessene (core.fn_household_persons). Konten ohne Auszug fehlen (unbekannt, nicht 0) ->
--   accounts nennt, aus wie vielen Konten die Zahl stammt. Keine Eingabe.
--   Konsumenten: fn_advisor_review (cashflow_coverage, savings_squeeze, Digest), fn_cashflow_coverage_fold,
--   fn_savings_squeeze_fold, fn_liquidity_snapshot (monthly_expenses_eur = Pflicht + Alltag -> Notreserve/Runway).
--   plpgsql: liest eine View aus einer alphabetisch spaeteren R__v_-Datei (late-bound).
--   Rueckgabe: (monthly_everyday <= 0 in EUR, accounts, provisional, has_fx_gap)
--   Tests: tests/db/finance/test_fn_household_everyday_month.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_household_everyday_month()
RETURNS TABLE(monthly_everyday numeric, accounts int, provisional boolean, has_fx_gap boolean)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT round(COALESCE(sum(finance.fn_to_eur(e.everyday_per_month, e.currency)), 0), 2),
           count(*)::int,
           COALESCE(bool_or(e.provisional), false),
           COALESCE(bool_or(e.everyday_per_month <> 0 AND finance.fn_to_eur(e.everyday_per_month, e.currency) IS NULL), false)
    FROM finance.account_everyday_spending e
    LEFT JOIN core.fn_household_persons() hp ON hp.person_id = e.owner_person_id
    WHERE e.has_history AND hp.role IS DISTINCT FROM 'child';
END;
$$;
