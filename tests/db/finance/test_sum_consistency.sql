-- ============================================================
-- test_sum_consistency — Σ-Tripwire fuer die trigger-gepflegten abgeleiteten Spalten.
--   Prueft die LIVE-Daten-Invarianten (read-only): heute true-by-construction (Trigger), kuenftig ein
--   Regressionsnetz, falls ein Trigger-Edit oder Direktzugriff den abgeleiteten Zustand bricht.
--   (a) finance_account_balances.balance == SUM(finance_transactions.amount) je Konto
--   (b) jedes Konto hat genau eine balance-Zeile (deckt das "ON CONFLICT DO NOTHING maskiert"-Finding ab)
--   (c) finance_depot_holdings.shares == SUM(finance_transactions.shares) je Holding
--   BEGIN/ROLLBACK (kein Write; reine Assertions).
-- ============================================================
BEGIN;
DO $$
DECLARE v_bad INT;
BEGIN
    -- (a) Saldo == Summe der Buchungen
    SELECT count(*) INTO v_bad FROM (
        SELECT b.account_id
        FROM finance.account_balances b
        WHERE b.balance <> COALESCE(
            (SELECT SUM(t.amount) FROM finance.transactions t WHERE t.account_id = b.account_id), 0)
    ) q;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'FAIL sum-consistency (a): % Konto/Konten mit balance <> SUM(tx.amount)', v_bad;
    END IF;

    -- (b) jedes Konto hat eine balance-Zeile
    SELECT count(*) INTO v_bad FROM finance.accounts a
    LEFT JOIN finance.account_balances b ON b.account_id = a.id
    WHERE b.account_id IS NULL;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'FAIL sum-consistency (b): % Konto/Konten ohne balance-Zeile', v_bad;
    END IF;

    -- (c) holding.shares == Summe der Anteils-Deltas
    SELECT count(*) INTO v_bad FROM (
        SELECT h.id
        FROM finance.depot_holdings h
        WHERE h.shares <> COALESCE(
            (SELECT SUM(t.shares) FROM finance.transactions t
             WHERE t.holding_id = h.id AND t.shares IS NOT NULL), 0)
    ) q;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'FAIL sum-consistency (c): % Holding(s) mit shares <> SUM(tx.shares)', v_bad;
    END IF;

    RAISE NOTICE 'PASS test_sum_consistency (balance/shares == SUM, jede balance-Zeile vorhanden)';
END $$;
ROLLBACK;
