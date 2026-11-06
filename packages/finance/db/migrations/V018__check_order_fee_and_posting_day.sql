-- ============================================================
-- V018 (finance) — zwei spiegelnde CHECKs der Import-Haertung (2026-10-22).
--
--   (a) transactions.order_fee >= 0 — eine negative Order-Gebuehr senkte die Anschaffungskosten (buy) bzw. erhoehte
--       den Erloes (sell) still. Freundlicher Guard: fn_book_stock_buy / fn_book_stock_sell ({ok:false}).
--   (b) account_interest_rates.posting_day_of_month 1-28 | NULL — Arrears-Gutschrift am n-ten des FOLGEmonats
--       (fn_interest_due_open: date_trunc('month', period_end) + 1 month + (n-1) Tage). -1 ("Monatsletzter", fuer
--       den Buchungstag erlaubt) laege dort VOR dem Periodenende, 29-31 overflowen kurze Monate. Freundlicher Guard:
--       fn_interest_terms_reason (fn_create_account + fn_interest_rate_preview/set_account_interest).
--
--   PRE-FLIGHT (fail-loud, Muster V012): Bestands-Zeilen ausserhalb der Domaene brechen die Migration mit ids ab —
--   still korrigieren waere schlimmer als ein sichtbarer Stopp. Single-User -> in der Praxis leer.
--   APPLY-ORDER: Inits -> V (hier) -> R. Re-run-sicher (DROP CONSTRAINT IF EXISTS + ADD).
-- ============================================================

-- (1) Pre-Flight
DO $$
DECLARE v_bad TEXT;
BEGIN
    SELECT string_agg(t || ' [' || ids || ']', '; ') INTO v_bad
    FROM (
        SELECT 'transactions.order_fee < 0' AS t, string_agg(id::text, ',' ORDER BY id) AS ids
          FROM finance.transactions
         WHERE order_fee < 0
        UNION ALL
        SELECT 'account_interest_rates.posting_day_of_month', string_agg(id::text, ',' ORDER BY id)
          FROM finance.account_interest_rates
         WHERE posting_day_of_month IS NOT NULL AND posting_day_of_month NOT BETWEEN 1 AND 28
    ) q
    WHERE q.ids IS NOT NULL;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'V018 pre-flight: Werte ausserhalb der Domaene in %. order_fee auf >= 0 bzw. den Gutschrift-Tag auf 1-28 (oder leer = Gutschrift am Periodenende) korrigieren, dann erneut migrieren.', v_bad;
    END IF;
END $$;

-- (2) CHECKs
DO $$ BEGIN
    ALTER TABLE finance.transactions DROP CONSTRAINT IF EXISTS finance_transactions_order_fee_chk;
    ALTER TABLE finance.transactions ADD CONSTRAINT finance_transactions_order_fee_chk
        CHECK (order_fee IS NULL OR order_fee >= 0);

    ALTER TABLE finance.account_interest_rates DROP CONSTRAINT IF EXISTS finance_air_posting_dom_chk;
    ALTER TABLE finance.account_interest_rates ADD CONSTRAINT finance_air_posting_dom_chk
        CHECK (posting_day_of_month IS NULL OR posting_day_of_month BETWEEN 1 AND 28);
END $$;
