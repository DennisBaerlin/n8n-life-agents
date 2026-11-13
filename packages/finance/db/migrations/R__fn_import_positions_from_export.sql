-- ============================================================
-- fn_import_positions_from_export (Staging-Write, kein HITL) -- offene Positionen der Datei als stock_buy einstellen
--   Eingabe: chat_id, table:{rows}. Je verbliebenem Kauf eine datierte Zeile mit cost_origin (Tranchen in fn_import_bundle), Depot
--   des Verrechnungskontos nach Art (Aktie/ETF oder Krypto). Ein unbestaetigter Stapel desselben Laufs wird ersetzt.
--   Karte und Write sind danach tool_commit_import.
--   Rueckgabe: {ok:true, batch_id, staged, invalid, errors, positions (Anzahl)} | {ok:false, reason} (Setup ohne Phase
--   'positions' oder Fehler aus fn_import_stage).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_positions_from_export(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_s     finance.setup_session%ROWTYPE;
    v_next  JSONB;
    v_acct  INT;
    v_depot TEXT;
    v_coin  TEXT;
    v_rows  JSONB;
    v_r     JSONB;
BEGIN
    SELECT * INTO v_s FROM finance.setup_session
    WHERE chat_id = p->>'chat_id' AND created_at > now() - interval '7 days' ORDER BY updated_at DESC LIMIT 1;
    v_next := finance.fn_setup_next(p);
    IF v_s.id IS NULL OR v_next->>'phase' IS DISTINCT FROM 'positions' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'The setup has no positions to stage right now.');
    END IF;
    v_acct := (v_next->>'account_id')::int;
    SELECT name INTO v_depot FROM finance.accounts WHERE settlement_account_id = v_acct AND status = 'active' AND account_type::text = 'stocks_depot' ORDER BY id LIMIT 1;
    SELECT name INTO v_coin FROM finance.accounts WHERE settlement_account_id = v_acct AND status = 'active' AND account_type::text = 'crypto_depot' ORDER BY id LIMIT 1;

    SELECT jsonb_agg(jsonb_build_object('entity_type', 'stock_buy',
               'depot', CASE WHEN (x->>'is_crypto')::boolean THEN v_coin ELSE v_depot END,
               'isin', x->>'isin', 'name', x->>'name', 'shares', (l->>'shares')::numeric,
               'price_per_share', (l->>'price')::numeric, 'order_fee', (l->>'fee')::numeric,
               'transaction_date', l->>'date', 'cost_origin', x->>'origin', 'setup_hints', x->'hints')
               || CASE WHEN (x->>'is_crypto')::boolean THEN jsonb_build_object('symbol', x->>'symbol') ELSE '{}'::jsonb END)
    INTO v_rows
    FROM jsonb_array_elements(v_next->'positions') x, jsonb_array_elements(x->'lots') l;

    IF v_s.batch_id IS NOT NULL THEN
        DELETE FROM finance.import_staging WHERE batch_id = v_s.batch_id AND status <> 'committed';
    END IF;
    v_r := finance.fn_import_stage(jsonb_build_object('source', 'csv', 'rows', v_rows, 'chat_id', p->>'chat_id'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_r;
    END IF;
    UPDATE finance.setup_session SET batch_id = (v_r->>'batch_id')::uuid, updated_at = now() WHERE id = v_s.id;
    RETURN jsonb_build_object('ok', true, 'batch_id', v_r->'batch_id', 'staged', v_r->'staged', 'invalid', v_r->'invalid',
                              'errors', v_r->'errors', 'positions', jsonb_array_length(v_next->'positions'));
END;
$$;
