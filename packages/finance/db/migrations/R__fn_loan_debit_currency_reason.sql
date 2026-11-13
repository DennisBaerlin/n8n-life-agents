-- ============================================================
-- fn_loan_debit_currency_reason (READ, STABLE) -- Waehrungs-Guard fuer Kredit-Zahlungen
--   Rate und Abloesung sind Betraege in Kreditwaehrung (Waehrung des Kreditkontos); zahlt ein Konto anderer
--   Waehrung, wuerde derselbe Betrag still als Fremdwaehrung abgebucht. Die eine Adresse fuer fn_book_loan_payment
--   und fn_settle_loan (fn_create_loan haelt Kredite in EUR).
--   Eingabe: p_debit_account_id (zahlendes Konto), p_loan_account_id (Kreditkonto), beide Pflicht.
--   Rueckgabe: NULL = gleiche Waehrung (oder ein Konto unbekannt -> die Aufrufer-Guards greifen) |
--   englischer reason-Text fuer {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_loan_debit_currency_reason(p_debit_account_id int, p_loan_account_id int)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT 'The paying account is kept in ' || d.currency || ' but the loan is in ' || l.currency
           || ' - pick an account in the loan currency (' || l.currency || ').'
    FROM finance.accounts d, finance.accounts l
    WHERE d.id = p_debit_account_id AND l.id = p_loan_account_id AND d.currency <> l.currency
$$;
