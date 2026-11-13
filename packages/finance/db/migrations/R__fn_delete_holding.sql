-- ============================================================
-- fn_delete_holding (ATOMIC WRITE) -- Hard-DELETE einer Fehlanlage / leeren Position
--   Nur fuer eine versehentlich angelegte oder nach vollstaendigem Void verwaiste Position (shares=0,
--   keine Buchungen); die Historie sind die verknuepften Trades (transactions.holding_id, FK RESTRICT).
--   Eingabe jsonb: holding_id (Pflicht; Agent liest sie via finance_depot_holdings_overview / postgres_select).
--   Rueckgabe: {ok:true, action:'deleted', holding_id}.
--   {ok:false} (kein RAISE -> kein Owner-Alert): >=1 verknuepfte Transaktion -> reason + transaction_count
--   (erst die Trades voiden). RAISE nur bei not-found.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_delete_holding(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id       INT := (p->>'holding_id')::int;
    v_tx_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM finance.depot_holdings WHERE id = v_id) THEN
        RAISE EXCEPTION 'Holding % not found.', v_id;
    END IF;

    -- Verknuepfte Trades als Daten statt hartem FK-Fehler.
    SELECT COUNT(*) INTO v_tx_count
    FROM finance.transactions WHERE holding_id = v_id;
    IF v_tx_count > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This holding has ' || v_tx_count
                   || ' trade transaction(s) and cannot be deleted. Void the trade(s) first.',
            'transaction_count', v_tx_count);
    END IF;

    DELETE FROM finance.depot_holdings WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'holding_id', v_id);
END;
$$;
