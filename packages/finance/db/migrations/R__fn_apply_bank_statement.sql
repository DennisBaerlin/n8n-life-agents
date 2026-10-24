-- ============================================================
-- fn_apply_bank_statement (ATOMIC WRITE) -- Kontoauszug buchen (Monats-Check WP-C)
--   Eingabe: dieselben Rohwerte wie fn_statement_prepare + fingerprint (aus der bestaetigten Vorschau).
--   Ablauf in EINER Transaktion: Salden der beteiligten Konten sperren -> fn_statement_prepare erneut (unter Lock;
--   anderer fingerprint -> {ok:false, code:'stale_preview'} ohne Write: zwischen Karte und Tipp hat sich etwas
--   geaendert) -> gelernte Kontonummer -> Abweichung vor dem Zeitraum als Abgleich am Schnitt-Tag -> je Treffer die
--   bestehende Buch-fn mit Ist-Betrag und Ist-Datum (Dauerauftrag/Transfer/Kredit ueber fn_book_recurring_occurrence,
--   Sparplan ueber fn_book_savings_plan_execution mit geschaetzten Stueck -> shares_estimated, Zins ueber
--   fn_book_interest_occurrence) -> Schluessel lernen -> Plan-Anpassungen (fn_split_recurring_payment) -> schon
--   gebuchte Zahlungen mit Buchungsdatum nach period_end aufs Zeilendatum verschieben (redated_count) -> Abgleich auf
--   den Endsaldo am period_end (bucht den Rest als EINE Abgleichsbuchung und ueberspringt die fehlenden Vorkommen) ->
--   Aggregat in finance.bank_statements, Herkunft bank_statement_id an jeder hier entstandenen Buchung.
--   Ein {ok:false} einer inneren Buch-fn wird zu RAISE SQLSTATE 'FN001' -> Rollback des Blocks -> {ok:false, reason}
--   (kein Teilzustand, kein Owner-Alarm).
--   RUECKGABE: {ok:true, statement_id, booked_count, booked_tx_ids[], drift_amount, lump_amount, skipped_occurrences, redated_count,
--   learned_keys, plan_adjusted[], savings_plan_estimated[], unknown_mandates[], balance_after,
--   outlook (= finance.fn_account_outlook, Deckungs-Vorschau bis zum naechsten Geldeingang)} | {ok:false, code?, reason}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_apply_bank_statement(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_prep     JSONB;
    v_acct     INT;
    v_prev_bal NUMERIC;
    v_prev_at  DATE;
    v_m        JSONB;
    v_r        JSONB;
    v_ids      INT[] := '{}';
    v_drift    NUMERIC;
    v_drift_tx INT;
    v_final    JSONB;
    v_skipped  JSONB := '[]'::jsonb;
    v_keys     INT[] := '{}';
    v_key_id   INT;
    v_k        JSONB;
    v_adjusted JSONB := '[]'::jsonb;
    v_spe      JSONB := '[]'::jsonb;
    v_stmt     INT;
    v_redated  INT := 0;
BEGIN
    v_prep := finance.fn_statement_prepare(p - 'fingerprint');
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_prep;
    END IF;
    v_acct := (v_prep->>'account_id')::int;

    -- Salden aller beteiligten Konten sperren (dieses Konto + Transfer-Gegenkonten), dann unter Lock neu rechnen.
    PERFORM 1 FROM finance.account_balances b
    WHERE b.account_id = v_acct
       OR b.account_id IN (SELECT CASE WHEN r.account_id = v_acct THEN r.target_account_id ELSE r.account_id END
                           FROM finance.recurring_payments r
                           WHERE r.id IN (SELECT (m->>'recurring_payment_id')::int
                                          FROM jsonb_array_elements(v_prep->'matched') m))
    ORDER BY b.account_id
    FOR UPDATE;
    v_prep := finance.fn_statement_prepare(p - 'fingerprint');
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_prep;
    END IF;
    IF v_prep->>'fingerprint' IS DISTINCT FROM p->>'fingerprint' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'stale_preview',
            'reason', 'Something changed since the card was shown - prepare the statement again and show a new card.');
    END IF;

    SELECT last_reconciled_balance, last_reconciled_at INTO v_prev_bal, v_prev_at FROM finance.accounts WHERE id = v_acct;

    BEGIN
        IF v_prep->>'learned_account_number' IS NOT NULL THEN
            v_r := finance.fn_set_account(jsonb_build_object('account_id', v_acct,
                       'account_number', v_prep->>'learned_account_number'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = v_r->>'reason';
            END IF;
        END IF;

        v_drift := (v_prep->>'drift')::numeric;
        IF v_drift <> 0 THEN
            v_r := finance.fn_reconcile_account(jsonb_build_object('account_id', v_acct,
                       'confirmed_balance', (v_prep->>'stmt_at_cut')::numeric,
                       'reconciliation_date', v_prep->>'cut', 'notes', 'Monats-Check: Abweichung vor dem Zeitraum'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = v_r->>'reason';
            END IF;
            v_drift_tx := NULLIF(v_r->>'reconciliation_tx_id', '')::int;
            v_ids := v_ids || v_drift_tx;
            v_skipped := v_skipped || COALESCE(v_r->'skipped', '[]'::jsonb);
        END IF;

        FOR v_m IN SELECT e FROM jsonb_array_elements(v_prep->'matched') e LOOP
            IF v_m->>'kind' = 'interest' THEN
                v_r := finance.fn_book_interest_occurrence(jsonb_build_object('account_id', v_acct,
                           'value_date', v_m->>'line_date', 'period_end', v_m->>'interest_period_end',
                           'amount', (v_m->>'amount')::numeric));
            ELSIF v_m->>'kind' = 'savings_plan' THEN
                v_r := finance.fn_book_savings_plan_execution(jsonb_build_object(
                           'recurring_payment_id', (v_m->>'recurring_payment_id')::int, 'due_date', v_m->>'due_date',
                           'transaction_date', v_m->>'line_date', 'shares', (v_m->>'shares')::numeric,
                           'price_per_share', (v_m->>'price_per_share')::numeric, 'order_fee', (v_m->>'order_fee')::numeric));
            ELSE
                v_r := finance.fn_book_recurring_occurrence(jsonb_build_object(
                           'recurring_payment_id', (v_m->>'recurring_payment_id')::int, 'due_date', v_m->>'due_date',
                           'amount', abs((v_m->>'amount')::numeric), 'transaction_date', v_m->>'line_date'));
            END IF;
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001',
                    MESSAGE = COALESCE(v_m->>'name', 'payment') || ': ' || COALESCE(v_r->>'reason', 'booking refused');
            END IF;
            v_ids := v_ids || ARRAY_REMOVE(ARRAY[NULLIF(v_r->>'transaction_id', '')::int, NULLIF(v_r->>'debit_tx_id', '')::int,
                                                 NULLIF(v_r->>'credit_tx_id', '')::int, NULLIF(v_r->>'buy_tx_id', '')::int], NULL);
            IF v_m->>'kind' = 'savings_plan' THEN
                UPDATE finance.transactions SET shares_estimated = true WHERE id = (v_r->>'buy_tx_id')::int;
                v_spe := v_spe || jsonb_build_object('name', v_m->>'name', 'shares', (v_m->>'shares')::numeric,
                                                     'holding_id', (v_r->>'holding_id')::int);
            END IF;
        END LOOP;

        FOR v_k IN SELECT e FROM jsonb_array_elements(v_prep->'learn') e LOOP
            INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
            VALUES ((v_k->>'recurring_payment_id')::int, (v_k->>'key_type')::finance.rp_key_type, v_k->>'key_value', 'statement')
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_key_id;
            IF v_key_id IS NOT NULL THEN v_keys := v_keys || v_key_id; END IF;
            v_key_id := NULL;
        END LOOP;

        FOR v_k IN SELECT e FROM jsonb_array_elements(v_prep->'plan_adjustments') e LOOP
            v_r := finance.fn_split_recurring_payment((v_k->>'recurring_payment_id')::int, (v_k->>'eff_from')::date,
                       (v_k->>'amount')::numeric, NULL, NULL, NULL, NULL, NULL, NULL);
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = (v_k->>'name') || ': ' || (v_r->>'reason');
            END IF;
            v_adjusted := v_adjusted || jsonb_build_object('name', v_k->>'name', 'eff_from', v_k->>'eff_from',
                                                           'amount', (v_k->>'amount')::numeric,
                                                           'recurring_payment_id', (v_r->>'recurring_payment_id')::int);
        END LOOP;

        -- Schon gebuchte Zahlung mit Buchungsdatum nach dem Auszugsende -> aufs Ist-Datum laut Auszug (alle Beine der
        -- Gruppe; die Verschiebbarkeit prueft fn_statement_match, prepare zaehlt sie schon zum Stand am period_end).
        FOR v_m IN SELECT e FROM jsonb_array_elements(v_prep->'already_booked') e
                   WHERE (e->>'tx_date')::date > (v_prep->>'period_end')::date LOOP
            UPDATE finance.transactions t SET transaction_date = (v_m->>'line_date')::date
            WHERE t.id = (v_m->>'transaction_id')::int
               OR t.group_id = (SELECT x.group_id FROM finance.transactions x
                                WHERE x.id = (v_m->>'transaction_id')::int AND x.group_id IS NOT NULL);
            v_redated := v_redated + 1;
        END LOOP;

        v_final := finance.fn_reconcile_account(jsonb_build_object('account_id', v_acct,
                       'confirmed_balance', (v_prep->>'closing_balance')::numeric, 'reconciliation_date', v_prep->>'period_end',
                       'notes', 'Monats-Check ' || (v_prep->>'period_start') || ' bis ' || (v_prep->>'period_end')));
        IF (v_final->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = v_final->>'reason';
        END IF;
        v_ids := v_ids || ARRAY_REMOVE(ARRAY[NULLIF(v_final->>'reconciliation_tx_id', '')::int], NULL);
        v_skipped := v_skipped || COALESCE(v_final->'skipped', '[]'::jsonb);

        INSERT INTO finance.bank_statements
            (account_id, period_start, period_end, opening_balance, closing_balance, currency, line_count, matched_count,
             unmatched_out, unmatched_in, prev_last_reconciled_balance, prev_last_reconciled_at, skipped, learned_key_ids)
        VALUES (v_acct, (v_prep->>'period_start')::date, (v_prep->>'period_end')::date,
                (v_prep->>'opening_balance')::numeric, (v_prep->>'closing_balance')::numeric, v_prep->>'currency',
                (v_prep->>'line_count')::int, (v_prep->>'matched_count')::int,
                (v_prep->>'unmatched_out')::numeric, (v_prep->>'unmatched_in')::numeric, v_prev_bal, v_prev_at,
                v_skipped, v_keys)
        RETURNING id INTO v_stmt;

        -- Herkunft: jede hier entstandene Buchung inkl. ihrer Gruppen-Beine (Transfer-Ziel, Kredit-Tilgung).
        UPDATE finance.transactions t SET bank_statement_id = v_stmt
        WHERE t.id = ANY(v_ids)
           OR t.group_id IN (SELECT x.group_id FROM finance.transactions x WHERE x.id = ANY(v_ids) AND x.group_id IS NOT NULL);
    EXCEPTION WHEN SQLSTATE 'FN001' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'booking_failed', 'reason', SQLERRM);
    END;

    RETURN jsonb_build_object('ok', true,
        'statement_id', v_stmt,
        'booked_count', jsonb_array_length(v_prep->'matched'),
        'booked_tx_ids', to_jsonb(v_ids),
        'drift_amount', v_drift,
        'lump_amount', COALESCE((v_final->>'difference')::numeric, 0),
        'skipped_occurrences', jsonb_array_length(v_skipped),
        'redated_count', v_redated,
        'learned_keys', cardinality(v_keys),
        'plan_adjusted', v_adjusted,
        'savings_plan_estimated', v_spe,
        'unknown_mandates', v_prep->'unknown_mandates',
        'balance_after', (SELECT balance FROM finance.account_balances WHERE account_id = v_acct),
        'outlook', finance.fn_account_outlook(v_acct));
END;
$$;
