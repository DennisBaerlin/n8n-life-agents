-- ============================================================
-- fn_clear_e2e_data (GEGUARDETES TEST-CLEANUP, finance-Teil — KEIN Produktiv-Tool)
--   Paket-Hook der Konvention <pkg>.fn_clear_e2e_data(text) (Phase B, docs/package-contract.md §6): der Core-
--   Dispatcher agent.fn_clear_e2e_data ruft ihn je installiertem Paket. Loescht ALLE finance-E2E-Entitaeten mit
--   dem Sentinel-Marker '__E2E__', FK-sicher und atomar (laeuft in der Transaktion des Dispatchers).
--   GUARD 1 (Pre-Assertion): jede eingesammelte Konto-ID MUSS den Marker tragen + Runaway-Obergrenze -> bricht VOR
--     jedem DELETE ab. GUARD 2 (Post-Assertion): keine finance-Sentinel-Zeile darf zurueckbleiben.
--   Jeder DELETE ist sentinel-/account-scoped. p_runid: NULL/'' = generischer Sweep, sonst nur '__E2E_<runid>__'.
--   RUECKGABE: flache Zaehler {accounts, transactions, holdings, savings_plans, insurances, loans, savings_goals,
--     real_estate, pension, recurring_payments, interest_rates, balances, import_staging}
--   Tests: tests/db/core/test_fn_clear_e2e_data.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_clear_e2e_data(p_runid text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pat  CONSTANT text := CASE WHEN COALESCE(p_runid,'') = '' THEN '\_\_E2E%'
                                 ELSE '\_\_E2E\_' || p_runid || '\_\_%' END;
    v_pat_any CONSTANT text := CASE WHEN COALESCE(p_runid,'') = '' THEN '%\_\_E2E%'
                                    ELSE '%\_\_E2E\_' || p_runid || '\_\_%' END;
    v_max  CONSTANT int  := 500;              -- Runaway-Obergrenze
    v_acct int[];
    v_rp   int[];
    v_n    int;
    v_tx int; v_hold int; v_sp int; v_ins int; v_loan int; v_sg int; v_re int; v_pen int; v_rpc int; v_ir int;
    v_bal int; v_ac int; v_stg int := 0;
BEGIN
    -- Run-ID-Format-Guard: nur [a-z0-9] (verhindert LIKE-Injection ueber p_runid).
    IF COALESCE(p_runid,'') <> '' AND p_runid !~ '^[a-z0-9]+$' THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: ungültige run-id % (nur [a-z0-9])', p_runid;
    END IF;

    -- Sentinel-Konten-IDs einsammeln: direkte Sentinel-Konten + die dedizierten Loan-Konten von Sentinel-Krediten
    -- (diese heissen 'Kredit __E2E__ ...' -> Prefix-Match wuerde sie verfehlen; settle_loan loescht sie nicht).
    SELECT COALESCE(array_agg(id), ARRAY[]::int[]) INTO v_acct FROM (
        SELECT id              FROM finance.accounts WHERE name LIKE v_pat
        UNION
        SELECT loan_account_id FROM finance.loans    WHERE name LIKE v_pat
    ) s;
    v_n := COALESCE(array_length(v_acct, 1), 0);

    -- GUARD 1: jede eingesammelte ID MUSS den Marker tragen ("Enthalten"-Pattern wegen 'Kredit __E2E__ ...').
    IF EXISTS (SELECT 1 FROM finance.accounts WHERE id = ANY(v_acct) AND name NOT LIKE v_pat_any) THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: Nicht-Sentinel-Konto in Löschmenge — Abbruch';
    END IF;
    IF v_n > v_max THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: % Sentinel-Konten > Obergrenze % — Abbruch', v_n, v_max;
    END IF;

    -- Recurring-Payments: referenziert von Sentinel-Stammdaten ODER von/auf ein Sentinel-Konto.
    SELECT COALESCE(array_agg(DISTINCT rp_id), ARRAY[]::int[]) INTO v_rp FROM (
        SELECT recurring_payment_id AS rp_id FROM finance.insurances    WHERE name LIKE v_pat AND recurring_payment_id IS NOT NULL
        UNION SELECT recurring_payment_id    FROM finance.loans         WHERE name LIKE v_pat AND recurring_payment_id IS NOT NULL
        UNION SELECT recurring_payment_id    FROM finance.savings_goals  WHERE name LIKE v_pat AND recurring_payment_id IS NOT NULL
        UNION SELECT recurring_payment_id    FROM finance.savings_plans  WHERE name LIKE v_pat AND recurring_payment_id IS NOT NULL
        UNION SELECT recurring_payment_id    FROM finance.pension        WHERE name LIKE v_pat AND recurring_payment_id IS NOT NULL
        UNION SELECT id                      FROM finance.recurring_payments WHERE account_id = ANY(v_acct) OR target_account_id = ANY(v_acct)
    ) s;

    -- Loeschreihenfolge (FK-sicher; alles sentinel-/account-scoped):
    -- 1. Transaktionen der Sentinel-Konten (oder via Sentinel-Holding/-Loan referenziert)
    DELETE FROM finance.transactions
     WHERE account_id = ANY(v_acct)
        OR holding_id IN (SELECT id FROM finance.depot_holdings WHERE account_id = ANY(v_acct))
        OR loan_id    IN (SELECT id FROM finance.loans          WHERE name LIKE v_pat);
    GET DIAGNOSTICS v_tx = ROW_COUNT;

    -- 2. Depot-Holdings der Sentinel-Konten
    DELETE FROM finance.depot_holdings WHERE account_id = ANY(v_acct);
    GET DIAGNOSTICS v_hold = ROW_COUNT;

    -- 3. Savings-Goal-Reserve-Journal (der account_id-FK NO ACTION wuerde den Depot-DELETE sonst blocken)
    DELETE FROM finance.savings_goal_reserve_entries
     WHERE account_id = ANY(v_acct)
        OR savings_goal_id IN (SELECT id FROM finance.savings_goals WHERE name LIKE v_pat);

    -- 4. Sentinel-Stammdaten, die recurring_payments referenzieren -> zuerst weg
    DELETE FROM finance.savings_plans WHERE name LIKE v_pat;  GET DIAGNOSTICS v_sp   = ROW_COUNT;
    DELETE FROM finance.insurances    WHERE name LIKE v_pat;  GET DIAGNOSTICS v_ins  = ROW_COUNT;
    DELETE FROM finance.loans         WHERE name LIKE v_pat;  GET DIAGNOSTICS v_loan = ROW_COUNT;
    DELETE FROM finance.savings_goals WHERE name LIKE v_pat;  GET DIAGNOSTICS v_sg   = ROW_COUNT;
    DELETE FROM finance.real_estate   WHERE name LIKE v_pat;  GET DIAGNOSTICS v_re   = ROW_COUNT;
    DELETE FROM finance.pension       WHERE name LIKE v_pat;  GET DIAGNOSTICS v_pen  = ROW_COUNT;

    -- 5. Recurring-Payments (jetzt referenzfrei)
    DELETE FROM finance.recurring_payments WHERE id = ANY(v_rp);  GET DIAGNOSTICS v_rpc = ROW_COUNT;

    -- 6. Zins-Raten + Zins-Skips (ON DELETE CASCADE griffe; explizit fuer Klarheit)
    DELETE FROM finance.account_interest_rates WHERE account_id = ANY(v_acct);  GET DIAGNOSTICS v_ir = ROW_COUNT;
    DELETE FROM finance.interest_skips WHERE account_id = ANY(v_acct);

    -- 7. Balance-Zeilen (kein CASCADE -> explizit vor dem Konto)
    DELETE FROM finance.account_balances WHERE account_id = ANY(v_acct);  GET DIAGNOSTICS v_bal = ROW_COUNT;

    -- 8. zuletzt die Sentinel-Konten selbst
    DELETE FROM finance.accounts WHERE id = ANY(v_acct);  GET DIAGNOSTICS v_ac = ROW_COUNT;

    -- 8b. Import-Staging-Rows, deren Payload den Sentinel traegt (payload-weiter Match)
    DELETE FROM finance.import_staging WHERE payload::text LIKE v_pat_any;  GET DIAGNOSTICS v_stg = ROW_COUNT;

    -- GUARD 2: keine finance-Sentinel-Zeile darf zurueckbleiben.
    IF EXISTS (SELECT 1 FROM finance.accounts     WHERE name LIKE v_pat)
    OR EXISTS (SELECT 1 FROM finance.insurances    WHERE name LIKE v_pat)
    OR EXISTS (SELECT 1 FROM finance.loans         WHERE name LIKE v_pat)
    OR EXISTS (SELECT 1 FROM finance.real_estate   WHERE name LIKE v_pat)
    OR EXISTS (SELECT 1 FROM finance.savings_goals  WHERE name LIKE v_pat)
    OR EXISTS (SELECT 1 FROM finance.savings_goal_reserve_entries WHERE account_id = ANY(v_acct))
    OR EXISTS (SELECT 1 FROM finance.savings_plans  WHERE name LIKE v_pat)
    OR EXISTS (SELECT 1 FROM finance.pension        WHERE name LIKE v_pat) THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: finance-Sentinel-Zeilen nach Cleanup noch vorhanden — Abbruch';
    END IF;

    RETURN jsonb_build_object(
        'accounts', v_ac, 'transactions', v_tx, 'holdings', v_hold,
        'savings_plans', v_sp, 'insurances', v_ins, 'loans', v_loan,
        'savings_goals', v_sg, 'real_estate', v_re, 'pension', v_pen, 'recurring_payments', v_rpc,
        'interest_rates', v_ir, 'balances', v_bal, 'import_staging', v_stg
    );
END;
$$;
