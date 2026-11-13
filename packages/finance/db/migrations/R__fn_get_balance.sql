-- ============================================================
-- fn_get_balance (READ)
--   Aktueller Saldo eines Kontos (aus finance.account_balances).
--   Eingabe: p_account_id. Rueckgabe: Saldo, NULL wenn account_id unbekannt.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_balance(p_account_id int)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT balance FROM finance.account_balances WHERE account_id = p_account_id;
$$;
