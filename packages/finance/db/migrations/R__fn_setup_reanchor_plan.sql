-- ============================================================
-- fn_setup_reanchor_plan (READ, STABLE) -- darf ein Konto auf den Anfang einer Datei mit gedrucktem Stand umgestellt werden?
--   Nur wenn die Datei sonst nichts bringt (Stichtag >= Zeitraumende) und das Konto unberuehrt ist: kein Abgleich, kein Auszug,
--   keine Buchung ausser dem Eroeffnungssaldo.
--   Eingabe: p_account_id, p_norm (Ergebnis von fn_bank_export_normalize).
--   RUECKGABE: {ok:true, opening_balance, opening_balance_date (Tag vor Zeitraumbeginn), opening_tx_id (null ohne
--   Eroeffnungsbuchung), previous_balance, previous_date, account_name, currency} | {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_reanchor_plan(p_account_id int, p_norm jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_a  finance.accounts%ROWTYPE;
    v_tx INT;
BEGIN
    SELECT * INTO v_a FROM finance.accounts WHERE id = p_account_id;
    IF v_a.id IS NULL OR (p_norm->>'printed_balance')::boolean IS DISTINCT FROM true THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'This file prints no balance of its own.');
    END IF;
    IF v_a.opening_balance_date IS NULL OR v_a.opening_balance_date < (p_norm->'statement'->>'period_end')::date THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'The file already reaches past the account start.');
    END IF;
    IF v_a.last_reconciled_at IS NOT NULL OR EXISTS (SELECT 1 FROM finance.bank_statements b WHERE b.account_id = p_account_id) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'The account already has a confirmed balance.');
    END IF;
    IF EXISTS (SELECT 1 FROM finance.transactions t
               WHERE t.account_id = p_account_id AND NOT (t.category::text = 'other' AND t.transaction_date = v_a.opening_balance_date)) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'The account already has bookings.');
    END IF;
    IF (SELECT count(*) FROM finance.transactions t WHERE t.account_id = p_account_id) > 1 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'The account already has bookings.');
    END IF;
    SELECT t.id INTO v_tx FROM finance.transactions t WHERE t.account_id = p_account_id;
    RETURN jsonb_build_object('ok', true, 'opening_tx_id', v_tx,
        'opening_balance', (p_norm->'statement'->>'opening_balance')::numeric,
        'opening_balance_date', (p_norm->'statement'->>'period_start')::date - 1,
        'previous_balance', finance.fn_get_balance(p_account_id), 'previous_date', v_a.opening_balance_date,
        'account_name', v_a.name, 'currency', v_a.currency);
END;
$$;
