-- ============================================================
-- fn_settlement_account_reason (READ, STABLE) -- warum ein Konto nicht Verrechnungskonto sein kann, sonst NULL
--   Die EINE Pruefung fuer fn_create_account und fn_set_account (Bank-Import-Modul Paket 2). Ein Verrechnungskonto
--   haben nur Depots (dort laufen Kaeufe/Verkaeufe) und P2P-Konten (das verifizierte Auszahlungskonto, z. B. Bondora:
--   der Monats-Check paart Ein-/Auszahlungen ohne Gegen-IBAN damit); CHECK finance_accounts_settlement_kind = Backstop.
--   Das Verrechnungskonto muss Geld tragen koennen (fn_bookable_account_reason), darf nicht das Konto selbst sein, bei
--   P2P ein Girokonto (cash) und bei gegebener Waehrung dieselbe Waehrung haben.
--   Eingabe: Kontoart, Waehrung (NULL = noch offen, Depot erbt sie), Verrechnungskonto-id (NULL -> NULL), eigene id (opt).
--   RUECKGABE: text (englisch, an den Agenten) | NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_settlement_account_reason(p_account_type text, p_currency text,
                                                                p_settlement_id int, p_account_id int DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_settlement_id IS NULL THEN NULL
        WHEN p_account_type NOT IN ('stocks_depot', 'crypto_depot', 'p2p')
            THEN 'Only depots and P2P accounts have a settlement account - leave it empty for this account type.'
        WHEN p_settlement_id = p_account_id THEN 'An account cannot be its own settlement account.'
        WHEN finance.fn_bookable_account_reason(p_settlement_id) IS NOT NULL THEN finance.fn_bookable_account_reason(p_settlement_id)
        WHEN (SELECT s.status FROM finance.accounts s WHERE s.id = p_settlement_id) IS DISTINCT FROM 'active'
            THEN 'The settlement account is not an active account.'
        WHEN p_account_type = 'p2p' AND (SELECT s.account_type::text FROM finance.accounts s WHERE s.id = p_settlement_id) <> 'cash'
            THEN 'The settlement account of a P2P account is the bank account it pays out to - choose a current (cash) account.'
        WHEN p_currency IS NOT NULL AND (SELECT s.currency FROM finance.accounts s WHERE s.id = p_settlement_id) <> p_currency
            THEN 'The account currency (' || p_currency || ') must match the currency of its settlement account ('
                 || (SELECT s.currency FROM finance.accounts s WHERE s.id = p_settlement_id) || ').'
    END;
$$;
