-- ============================================================
-- fn_delete_account (ATOMIC WRITE) -- Hard-DELETE einer Konto-Fehlanlage
--   Delete-if-empty: jede Referenz aus Ledger/Stammdaten haelt das Konto (FK RESTRICT) und fuehrt zu
--   {ok:false}; close_account deckt den Soft-Close-Fall ab.
--   Eingabe jsonb: account_name (Pflicht; Resolve findet auch closed-Konten, p_active_only=FALSE).
--   Rueckgabe: {ok:true, action:'deleted', account_id}.
--   {ok:false} (kein RAISE -> kein Owner-Alert), je mit Count fuer Test-Stabilitaet:
--     - code 'not_found' (candidates []) / 'ambiguous' (candidates)
--     - reason + transaction_count, holding_count, recurring_payment_count (abbuchend),
--       recurring_target_count (Ziel eines Uebertrags), reserve_entry_count (Sparziel-Reserve-Journal),
--       savings_plan_count (depot_id), loan_count (loan/debit/disbursement-Konto),
--       depot_count (Verrechnungskonto eines Depots oder P2P-Kontos).
--   Seiteneffekt: loescht account_interest_rates und die account_balances-Zeile (kein CASCADE) vor dem Konto.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_delete_account(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name    TEXT := p->>'account_name';
    v_resolve RECORD;
    v_id      INT;
    v_cnt     INT;
BEGIN
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_account(v_name, NULL, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Account "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple accounts match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;
    v_id := v_resolve.id;

    -- Referenz-Guards als Daten statt hartem FK-Fehler.
    SELECT COUNT(*) INTO v_cnt FROM finance.transactions WHERE account_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account has ' || v_cnt || ' transaction(s) and cannot be deleted. '
                   || 'Use close_account to deactivate it instead.', 'transaction_count', v_cnt);
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM finance.depot_holdings WHERE account_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account has ' || v_cnt || ' depot holding(s) and cannot be deleted.',
            'holding_count', v_cnt);
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE account_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account is the debit account for ' || v_cnt || ' recurring payment(s) and cannot be deleted.',
            'recurring_payment_count', v_cnt);
    END IF;

    -- Ziel eines Dauer-Uebertrags (target_account_id, FK).
    SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE target_account_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account is the target of ' || v_cnt || ' recurring transfer(s) and cannot be deleted.',
            'recurring_target_count', v_cnt);
    END IF;

    -- Das Abbuchungskonto einer Versicherung steht nur an ihrer Beitrags-rp, die Pruefung oben deckt es.

    -- Reserve-Journal (jedes zuordenbare Konto): bewusst die Zeilen-Anzahl, nicht der Netto-Anteil. Das Journal ist
    -- append-only und der FK RESTRICT haelt auch eine freigegebene (Netto-0-)Spur fest.
    SELECT COUNT(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE account_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account has ' || v_cnt || ' savings-goal earmark entr(ies) and cannot be deleted '
                   || '(the earmark history stays). Close the account instead.', 'reserve_entry_count', v_cnt);
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM finance.savings_plans WHERE depot_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account is the depot for ' || v_cnt || ' savings plan(s) and cannot be deleted.',
            'savings_plan_count', v_cnt);
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM finance.loans
    WHERE loan_account_id = v_id OR debit_account_id = v_id OR disbursement_account_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account is referenced by ' || v_cnt || ' loan(s) and cannot be deleted.',
            'loan_count', v_cnt);
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM finance.accounts WHERE settlement_account_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This account is the settlement account for ' || v_cnt
                   || ' depot(s) or P2P account(s) and cannot be deleted. Re-link or close them first.',
            'depot_count', v_cnt);
    END IF;

    -- interest_rates gehen per CASCADE (explizit geloescht), die balance-Zeile hat kein CASCADE.
    DELETE FROM finance.account_interest_rates WHERE account_id = v_id;
    DELETE FROM finance.account_balances WHERE account_id = v_id;
    DELETE FROM finance.accounts WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'account_id', v_id);
END;
$$;
