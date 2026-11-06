-- ============================================================
-- fn_get_balance_as_of (READ) -- Saldo eines Kontos zum Ende eines Stichtags
--   Summe aller Buchungen mit transaction_date <= p_date (eine Buchung AM Stichtag zaehlt mit). EINE Adresse fuer
--   den Abgleich mit vergangenem Datum (Audit Paket 2, Punkt 6): fn_reconcile_account, fn_reconcile_accounts_preview
--   und die HITL-Karte von tool_reconcile_account vergleichen damit -- vorher mit dem HEUTIGEN Saldo ("am 15. waren
--   es 1000", spaeter +300 gebucht -> Korrektur -300 statt 0). Konto ohne Buchungen -> 0; unbekanntes Konto -> NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_balance_as_of(p_account_id int, p_date date)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT sum(t.amount) FROM finance.transactions t
                     WHERE t.account_id = a.id AND t.transaction_date <= p_date), 0)
    FROM finance.accounts a
    WHERE a.id = p_account_id;
$$;
