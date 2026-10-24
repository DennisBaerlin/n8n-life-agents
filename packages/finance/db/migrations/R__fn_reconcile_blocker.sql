-- ============================================================
-- fn_reconcile_blocker (READ HELPER) -- korrigierbare Gruende gegen einen Saldo-Abgleich (Audit Paket 2, Punkt 6/7)
--   EINE Adresse fuer fn_reconcile_account, fn_reconcile_accounts (Pass 1) und fn_reconcile_accounts_preview ->
--   Vorschau und Buchung lehnen identisch ab. NULL = abgleichbar, sonst der Grund (EN, fuers {ok:false}):
--     * Depot-/Kreditkonto (fn_bookable_account_reason),
--     * Stichtag in der Zukunft,
--     * Stichtag VOR dem letzten Abgleich (eine Korrektur dort verschoebe einen schon bestaetigten Saldo).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reconcile_blocker(p_account_id int, p_date date)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        finance.fn_bookable_account_reason(a.id),
        CASE WHEN p_date > core.fn_today() THEN
            'The reconciliation date ' || p_date || ' for account "' || a.name || '" is in the future; use today or an earlier date.'
        END,
        CASE WHEN a.last_reconciled_at IS NOT NULL AND p_date < a.last_reconciled_at THEN
            'Account "' || a.name || '" was already reconciled on ' || a.last_reconciled_at || '. A correction dated '
            || p_date || ' would change that confirmed balance; use a date on or after ' || a.last_reconciled_at || '.'
        END)
    FROM finance.accounts a
    WHERE a.id = p_account_id;
$$;
