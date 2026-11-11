-- ============================================================
-- test_fn_statement_prepare -- Rueckgabe-Felder fuer die Dauerauftrags-Erkennung auf einem bestaetigten Monat
--   already_covered und already_imported tragen account_id und balance_verified (Saldo-Probe), der Fingerprint und
--   die uebrigen Codes bleiben (test_bank_statement*). Erfundene IBAN.
-- ============================================================
BEGIN;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_acct INT;
    v_stmt JSONB;
    v_r    JSONB;
BEGIN
    v_acct := (finance.fn_create_account(jsonb_build_object('name', '__t_sp_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'account_number', 'DE89370400440532013000', 'opening_balance', 1000, 'opening_balance_date', (T - 40)::text))->>'account_id')::int;
    v_stmt := jsonb_build_object('account_number', 'DE89 3704 0044 0532 0130 00', 'currency', 'EUR',
        'period_start', (T - 70)::text, 'period_end', (T - 41)::text, 'opening_balance', 1100, 'closing_balance', 1000,
        'lines', jsonb_build_array(jsonb_build_object('date', (T - 60)::text, 'amount', -100, 'counterparty', 'Vermieter Test',
                                                      'counterparty_iban', '', 'creditor_id', '', 'mandate_ref', '', 'purpose', 'Miete')));
    -- Zeitraum endet vor dem Startbetrag -> already_covered (nach der Saldo-Probe, die hier stimmt)
    v_r := finance.fn_statement_prepare(v_stmt);
    IF v_r->>'code' IS DISTINCT FROM 'already_covered' OR (v_r->>'account_id')::int IS DISTINCT FROM v_acct
       OR (v_r->>'balance_verified')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [already_covered + account_id + balance_verified true]: %', v_r;
    END IF;
    -- bestaetigt bis period_end (last_reconciled_at)
    UPDATE finance.accounts SET last_reconciled_at = T - 41 WHERE id = v_acct;
    v_r := finance.fn_statement_prepare(v_stmt);
    IF v_r->>'code' IS DISTINCT FROM 'already_covered' OR (v_r->>'account_id')::int IS DISTINCT FROM v_acct
       OR (v_r->>'balance_verified')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [bestaetigt: already_covered + Felder]: %', v_r;
    END IF;
    -- bestaetigt: der Ruecksprung kommt vor der Saldo-Pflicht, die Probe steht im Feld
    v_r := finance.fn_statement_prepare(v_stmt || jsonb_build_object('closing_balance', 990));
    IF v_r->>'code' IS DISTINCT FROM 'already_covered' OR (v_r->>'balance_verified')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [already_covered, Saldo-Probe falsch -> balance_verified false]: %', v_r;
    END IF;
    RAISE NOTICE 'PASS [fn_statement_prepare already_covered traegt account_id + balance_verified]';
END $$;
ROLLBACK;
