-- ============================================================
-- fn_void_bank_statement (ATOMIC WRITE) -- den LETZTEN Kontoauszug eines Kontos zuruecknehmen (Monats-Check WP-C)
--   Nur der juengste Auszug (LIFO): jeder spaetere Abgleich baut auf ihm auf. Nimmt in EINER Transaktion zurueck:
--   alle Buchungen mit seiner Herkunft (bank_statement_id, je Gruppe ueber fn_void_transaction — Kredit-/Sparplan-/
--   Reserve-Folgen inklusive), die beim Abgleich gesetzten Skips (bank_statements.skipped), die gelernten Schluessel
--   (learned_key_ids), den Abgleichsstand davor (prev_last_reconciled_*) und das Aggregat selbst (gibt den Zeitraum
--   fuer ein erneutes Einspielen frei). Bewusst NICHT: eine gelernte Kontonummer und Plan-Anpassungen (eigene
--   Stammdaten-Aenderungen; Korrektur ueber set_account / set_recurring_payment).
--   Void-Schutz: liegt ein Transfer-Bein dieses Auszugs auf einem anderen Konto, das an dessen Datum schon abgeglichen
--   ist (dessen Auszug kam danach), -> {ok:false, code:'partner_reconciled', account} ohne Write (erst dort zuruecknehmen).
--   Eine Bein-Verschiebung an der Monatsgrenze (moved_legs) bleibt bestehen (Datum innerhalb der eigenen Gruppe).
--   Eingabe jsonb: account_id.
--   RUECKGABE: {ok:true, voided_tx_count, period_start, period_end, restored_last_reconciled_at}
--   | {ok:false, code?, account?, reason}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_void_bank_statement(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_acct  INT := (p->>'account_id')::int;
    v_s     finance.bank_statements%ROWTYPE;
    v_last  DATE;
    v_tx    INT;
    v_r     JSONB;
    v_n     INT := 0;
    v_partner TEXT;
BEGIN
    PERFORM 1 FROM finance.account_balances WHERE account_id = v_acct FOR UPDATE;
    SELECT * INTO v_s FROM finance.bank_statements WHERE account_id = v_acct ORDER BY period_end DESC LIMIT 1;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'No imported statement exists for this account.');
    END IF;
    SELECT last_reconciled_at INTO v_last FROM finance.accounts WHERE id = v_acct;
    IF v_last IS DISTINCT FROM v_s.period_end THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The balance was confirmed again after this statement (on ' || v_last
                   || '); the statement can no longer be taken back on its own.');
    END IF;
    -- Void-Schutz (Bank-Import-Modul): ein Transfer-Bein dieses Auszugs auf einem ANDEREN Konto, das an dessen Datum
    -- schon abgeglichen ist, steckt in dessen bestaetigtem Stand -> Loeschen wuerde ihn still falsch machen.
    SELECT a.name INTO v_partner
    FROM finance.transactions t JOIN finance.accounts a ON a.id = t.account_id
    WHERE t.account_id <> v_acct
      AND t.bank_statement_id = v_s.id   -- apply stempelt jedes Bein seiner Gruppen
      AND finance.fn_reconciled_reason(t.account_id, t.transaction_date) IS NOT NULL
    ORDER BY a.name LIMIT 1;
    IF v_partner IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'partner_reconciled', 'account', v_partner,
            'reason', 'This statement booked a transfer with "' || v_partner || '", whose balance was confirmed afterwards - '
                   || 'take back the latest statement of "' || v_partner || '" first.');
    END IF;

    BEGIN
        LOOP
            SELECT id INTO v_tx FROM finance.transactions WHERE bank_statement_id = v_s.id ORDER BY id DESC LIMIT 1;
            EXIT WHEN v_tx IS NULL;
            v_r := finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = COALESCE(v_r->>'reason', 'a booking could not be taken back');
            END IF;
            v_n := v_n + COALESCE((v_r->>'deleted_count')::int, 1);
            v_tx := NULL;
        END LOOP;

        DELETE FROM finance.recurring_payment_skips s
        USING jsonb_array_elements(v_s.skipped) x
        WHERE x ? 'recurring_payment_id'
          AND s.recurring_payment_id = (x->>'recurring_payment_id')::int AND s.due_date = (x->>'due_date')::date;
        DELETE FROM finance.interest_skips s
        USING jsonb_array_elements(v_s.skipped) x
        WHERE x ? 'interest_period_end' AND s.account_id = v_acct AND s.period_end = (x->>'interest_period_end')::date;
        DELETE FROM finance.recurring_payment_keys WHERE id = ANY(v_s.learned_key_ids);

        UPDATE finance.accounts
        SET last_reconciled_balance = v_s.prev_last_reconciled_balance,
            last_reconciled_at      = v_s.prev_last_reconciled_at
        WHERE id = v_acct;
        DELETE FROM finance.bank_statements WHERE id = v_s.id;
    EXCEPTION WHEN SQLSTATE 'FN001' THEN
        RETURN jsonb_build_object('ok', false, 'reason', SQLERRM);
    END;

    RETURN jsonb_build_object('ok', true, 'voided_tx_count', v_n,
        'period_start', v_s.period_start, 'period_end', v_s.period_end,
        'restored_last_reconciled_at', v_s.prev_last_reconciled_at);
END;
$$;
