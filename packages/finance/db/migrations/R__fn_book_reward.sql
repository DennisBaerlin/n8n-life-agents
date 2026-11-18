-- ============================================================
-- fn_book_reward (WRITE-Baustein) -- Staking-Ertrag als Stueck-Zugang ohne Geld buchen
--   Die eine Adresse fuer Monats-Check (fn_apply_bank_statement) und Ersteinrichtung (fn_import_bundle). Kein Agent-Tool:
--   die Aufrufer pruefen Depot und Verrechnungskonto vorher und laufen in ihrer eigenen Transaktion.
--   Position des Depots per ISIN bzw. Symbol (fn_depot_holding_id), fehlt sie, wird sie in Depot-Waehrung angelegt.
--   Buchung auf dem Verrechnungskonto (Depots tragen keine Buchung): category reward, amount 0, Einstand 0
--   (fn_holding_avg_cost); Form-CHECK finance_transactions_reward_shape ist der Backstop.
--   plpgsql (late-bound): fn_depot_holding_id liegt alphabetisch spaeter (R__fn_book_stock_buy.sql).
--   Eingabe: p_depot, p_settle, p_isin (NULL bei Krypto), p_symbol, p_name, p_shares (> 0), p_date, p_group (opt: Gruppe
--   der Lots-Ersetzung fn_replace_takeover_apply, ein Write = eine group_id = ein Void).
--   Rueckgabe: {ok:true, transaction_id, holding_id, shares (Bestand danach)}.
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_book_reward(int, int, text, text, text, numeric, date);
CREATE OR REPLACE FUNCTION finance.fn_book_reward(p_depot int, p_settle int, p_isin text, p_symbol text, p_name text,
                                                  p_shares numeric, p_date date, p_group uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_hold INT;
    v_tx   INT;
BEGIN
    v_hold := finance.fn_depot_holding_id(p_depot, p_isin, p_symbol, jsonb_build_object('name', p_name,
                  'currency', (SELECT d.currency FROM finance.accounts d WHERE d.id = p_depot)));
    INSERT INTO finance.transactions (account_id, holding_id, category, amount, shares, transaction_date, description, group_id)
    VALUES (p_settle, v_hold, 'reward', 0, p_shares, p_date, 'Staking ' || p_symbol, p_group)
    RETURNING id INTO v_tx;
    RETURN jsonb_build_object('ok', true, 'transaction_id', v_tx, 'holding_id', v_hold,
        'shares', (SELECT h.shares FROM finance.depot_holdings h WHERE h.id = v_hold));
END;
$$;
