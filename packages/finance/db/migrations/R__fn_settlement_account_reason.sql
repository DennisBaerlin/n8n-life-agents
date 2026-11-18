-- ============================================================
-- fn_settlement_account_reason (READ, STABLE) -- warum ein Konto nicht Verrechnungskonto sein kann, sonst NULL
--   Die eine Pruefung fuer fn_create_account und fn_set_account (Bank-Import-Modul). Ein Verrechnungskonto
--   haben nur Depots (dort laufen Kaeufe/Verkaeufe), P2P-Konten (das verifizierte Auszahlungskonto, z. B. Bondora:
--   der Monats-Check paart Ein-/Auszahlungen ohne Gegen-IBAN damit) und Geld-Konten (cash) eines Anbieters, dessen
--   Export-Profil ein counterparty_pattern traegt (Euro-Guthaben einer Krypto-Boerse: das Girokonto, auf das sie
--   auszahlt); CHECK finance_accounts_settlement_kind = Backstop der Kontoarten.
--   Das Verrechnungskonto muss Geld tragen koennen (fn_bookable_account_reason), darf nicht das Konto selbst sein, bei
--   P2P und cash ein Girokonto (cash) und bei gegebener Waehrung dieselbe Waehrung haben.
--   Eingabe: Kontoart, Waehrung (NULL = noch offen, Depot erbt sie), Verrechnungskonto-id (NULL -> NULL), eigene id (opt),
--   Bank oder Name des Kontos (opt; ohne: aus der eigenen id) fuer die Profil-Zuordnung per bank_pattern.
--   RUECKGABE: text (englisch, an den Agenten) | NULL.
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_settlement_account_reason(text, text, int, int);
CREATE OR REPLACE FUNCTION finance.fn_settlement_account_reason(p_account_type text, p_currency text,
                                                                p_settlement_id int, p_account_id int DEFAULT NULL,
                                                                p_bank_or_name text DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_settlement_id IS NULL THEN NULL
        WHEN p_account_type NOT IN ('stocks_depot', 'crypto_depot', 'p2p', 'cash')
          OR (p_account_type = 'cash' AND NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr
                WHERE pr ? 'counterparty_pattern'
                  AND COALESCE(NULLIF(trim(p_bank_or_name), ''),
                               (SELECT COALESCE(NULLIF(trim(a.bank), ''), a.name) FROM finance.accounts a WHERE a.id = p_account_id))
                      ~* (pr->>'bank_pattern')))
            THEN 'Only depots, P2P accounts and the cash account of a provider whose export lists transfers without the bank account have a settlement account - leave it empty for this account.'
        WHEN p_settlement_id = p_account_id THEN 'An account cannot be its own settlement account.'
        WHEN finance.fn_bookable_account_reason(p_settlement_id) IS NOT NULL THEN finance.fn_bookable_account_reason(p_settlement_id)
        WHEN (SELECT s.status FROM finance.accounts s WHERE s.id = p_settlement_id) IS DISTINCT FROM 'active'
            THEN 'The settlement account is not an active account.'
        WHEN p_account_type IN ('p2p', 'cash') AND (SELECT s.account_type::text FROM finance.accounts s WHERE s.id = p_settlement_id) <> 'cash'
            THEN 'The settlement account of this account is the bank account it pays out to - choose a current (cash) account.'
        WHEN p_currency IS NOT NULL AND (SELECT s.currency FROM finance.accounts s WHERE s.id = p_settlement_id) <> p_currency
            THEN 'The account currency (' || p_currency || ') must match the currency of its settlement account ('
                 || (SELECT s.currency FROM finance.accounts s WHERE s.id = p_settlement_id) || ').'
    END;
$$;
