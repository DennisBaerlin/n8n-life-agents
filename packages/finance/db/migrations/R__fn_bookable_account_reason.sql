-- ============================================================
-- fn_bookable_account_reason (READ HELPER) -- Kontotyp-Guard fuer freie Geld-Buchungen (Audit Paket 2, Punkt 7)
--   EINE Adresse fuer book_transaction / book_transfer / book_recurring_transfer / reconcile_account(s)(_preview):
--   liefert NULL, wenn auf das Konto frei gebucht werden darf, sonst den korrigierbaren Grund (EN, fuers {ok:false}).
--     * stocks_depot/crypto_depot: ein Depot-Konto traegt nie Geld (der Wert steckt in den Positionen; das Konto
--       zaehlt nicht im Vermoegen) -> eine Buchung dort liess Geld still aus dem Vermoegen verschwinden.
--     * loan: die Restschuld bewegen nur die Kredit-Tools (mit loan_id) -> sonst Restschuld ohne Kredit
--       (Abgleich "Restschuld 298000" buchte +298000).
--   Struktureller Backstop: trg_finance_reject_account_type_txn (Init). Unbekanntes Konto -> NULL (der Aufrufer
--   behandelt not-found wie bisher).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bookable_account_reason(p_account_id int)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN a.account_type IN ('stocks_depot', 'crypto_depot') THEN
            'Account "' || a.name || '" is a depot account: it holds positions, not cash. Book cash movements on its '
            || 'settlement account and trades with book_stock_buy / book_stock_sell.'
        WHEN a.account_type = 'loan' THEN
            'Account "' || a.name || '" is a loan account: its remaining debt only changes through the loan tools '
            || '(book_loan_payment, settle_loan, set_loan).'
    END
    FROM finance.accounts a
    WHERE a.id = p_account_id;
$$;
