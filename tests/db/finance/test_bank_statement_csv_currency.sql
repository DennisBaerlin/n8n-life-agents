-- ============================================================
-- test_bank_statement_csv_currency -- Monats-Check aus dem Broker-Export: Waehrungspruefung nur auf Zeilen, die zaehlen
--   fn_statement_prepare (source:'file'): eine Zeile in fremder Waehrung lehnt die Datei nur ab, wenn sie gebucht wuerde
--   (im Zeitraum, als spaete Zeile der Vorperiode) oder nach dem Zeitraum in den Stand einfliesst. Eine Zeile vor dem
--   bestaetigten Tag aendert nichts und darf die Datei nicht sperren.
--   Werte erfunden, Daten relativ zu core.fn_today(). Konto EUR, Startsaldo 1000 am heute-20.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.cur_row(p_d date, p_amt text, p_cur text, p_id text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text || 'T10:00:00Z', p_d::text, 'DEFAULT', 'CASH', 'CARD_TRANSACTION', '', '', '', '',
                             '', p_amt, '', '', p_cur, '', '', '', 'Test', p_id, '', '', '', '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_acc  INT;
    v_base JSONB;
    v_p    JSONB;
    v_res  JSONB;
    v_app  JSONB;
BEGIN
    v_acc := (finance.fn_create_account(jsonb_build_object('name', '__t_cur_tr__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_base := jsonb_build_array(pg_temp.cur_row(T - 5, '-30.000000', 'EUR', 'cu-01'));

    -- W1: fremde Waehrung nur VOR dem bestaetigten Tag -> Datei gilt, Zeile zaehlt nicht
    v_p := jsonb_build_object('source', 'file', 'account_name', '__t_cur_tr__', 'closing_balance', 970,
               'table', jsonb_build_object('rows', jsonb_build_array(v_hdr) || v_base
                   || jsonb_build_array(pg_temp.cur_row(T - 25, '12.000000', 'CHF', 'cu-02'))));
    v_res := finance.fn_statement_prepare(v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'lump')::numeric IS DISTINCT FROM -30 THEN
        RAISE EXCEPTION 'FAIL [W1 fremde Waehrung vor dem Schnitt]: %', v_res - 'card_lines'; END IF;
    RAISE NOTICE 'PASS [W1 fremde Waehrung vor dem Schnitt sperrt nicht]';

    -- W2: fremde Waehrung IM Zeitraum -> currency_mismatch
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array(v_hdr) || v_base || jsonb_build_array(pg_temp.cur_row(T - 4, '12.000000', 'CHF', 'cu-03')))));
    IF v_res->>'code' IS DISTINCT FROM 'currency_mismatch' THEN RAISE EXCEPTION 'FAIL [W2 im Zeitraum]: %', v_res - 'card_lines'; END IF;
    RAISE NOTICE 'PASS [W2 fremde Waehrung im Zeitraum -> currency_mismatch]';

    -- W3: fremde Waehrung NACH dem Zeitraum (heute) -> fliesst in den Stand ein -> currency_mismatch
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array(v_hdr) || v_base || jsonb_build_array(pg_temp.cur_row(T, '12.000000', 'CHF', 'cu-04')))));
    IF v_res->>'code' IS DISTINCT FROM 'currency_mismatch' THEN RAISE EXCEPTION 'FAIL [W3 nach dem Zeitraum]: %', v_res - 'card_lines'; END IF;
    RAISE NOTICE 'PASS [W3 fremde Waehrung nach dem Zeitraum -> currency_mismatch]';

    -- W4: spaete Zeile der Vorperiode (Referenz dort nicht gesehen) in fremder Waehrung -> wuerde gebucht -> currency_mismatch
    v_res := finance.fn_statement_prepare(v_p);
    v_app := finance.fn_apply_bank_statement(v_p || jsonb_build_object('fingerprint', v_res->>'fingerprint'));
    IF (v_app->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP W4 apply: %', v_app; END IF;
    UPDATE finance.bank_statements SET period_end = T - 3 WHERE id = (v_app->>'statement_id')::int;
    UPDATE finance.accounts SET last_reconciled_at = T - 3 WHERE id = v_acc;
    v_res := finance.fn_statement_prepare(v_p || jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array(v_hdr) || v_base || jsonb_build_array(pg_temp.cur_row(T - 7, '12.000000', 'CHF', 'cu-05')))));
    IF v_res->>'code' IS DISTINCT FROM 'currency_mismatch' THEN RAISE EXCEPTION 'FAIL [W4 spaete Zeile]: %', v_res - 'card_lines'; END IF;
    -- Gegenprobe: dieselbe Lage, die fremde Zeile liegt vor der Vorperiode -> gilt
    v_res := finance.fn_statement_prepare(v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [W4b vor der Vorperiode]: %', v_res - 'card_lines'; END IF;
    RAISE NOTICE 'PASS [W4 spaete fremde Zeile -> currency_mismatch, davor gilt]';
END $$;
ROLLBACK;
