-- ============================================================
-- finance.fn_liability_register (WS-0b estate — Provider-Lesefenster fuers Nachlass-Register)
--   Publizierte, provider-eigene Lese-fn (docs/package-contract.md "Cross-package reads / provides.reads",
--   Oberflaeche A): liefert die OFFENEN Kredite (finance.fn_loan_is_outstanding = active ODER paused, die EINE
--   Schulden-Definition, Audit Paket 2) mit der Restschuld (EUR-Basis), aus denen der estate-Agent (WS-1/2) die im
--   Todes-/Vorsorgefall fortbestehenden Verbindlichkeiten (wer schuldet wem wie viel) ableitet. Abgeloeste/
--   refinanzierte Kredite (paid_off/refinanced) sind irrelevant und fallen raus. finance BESITZT die Berechnung
--   (Restschuld = negativer Saldo im Loan-Konto), estate referenziert.
--
--   PLAIN STABLE, KEIN SECURITY DEFINER, KEIN Grant: gelesen render-at-fetch IM core.fn_fetch_context-
--   DEFINER (Owner=Superuser) -> kein neuer Grant. Call-Site doppel-guardet (fn_package_active('finance')
--   + to_regprocedure) -> finance absent = graceful NULL.
--
--   RAISE-FREI + COALESCE'd (laeuft IM Render-Fetch). Keine offenen Kredite -> '[]'::jsonb (nie NULL).
--   Liest finance.loan_overview (current_remaining_debt_eur = fn_to_eur der Restschuld -> Multi-Waehrung).
--
--   RUECKGABE jsonb-ARRAY je offenem Kredit: { id, name, lender, borrower_person_id, original_amount,
--   current_remaining_debt_eur, currency, status }. current_remaining_debt_eur ist der BETRAG der Schuld (positiv,
--   Audit Paket 2 -- vorher -200000 -> estate rendert "Restschuld ~-200000 EUR"); loan_overview bleibt
--   vorzeichenbehaftet (negativer Saldo). NULL = Restschuld in Fremdwaehrung ohne Kurs (estate laesst die Zahl weg).
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_liability_register.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_liability_register()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',                         id,
        'name',                       name,
        'lender',                     lender,
        'borrower_person_id',         borrower_person_id,
        'original_amount',            original_amount,
        'current_remaining_debt_eur', CASE WHEN current_remaining_debt_eur IS NOT NULL
                                           THEN GREATEST(-current_remaining_debt_eur, 0) END,
        'currency',                   currency,
        'status',                     status::text
    ) ORDER BY name), '[]'::jsonb)
    FROM finance.loan_overview
    WHERE finance.fn_loan_is_outstanding(status);
$$;
