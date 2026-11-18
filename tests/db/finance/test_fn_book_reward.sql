-- ============================================================
-- test_fn_book_reward -- Staking-Ertrag buchen (die eine Adresse fuer Monats-Check und Ersteinrichtung)
--   Position fehlt -> wird im Depot angelegt (Waehrung des Depots), Buchung auf dem Verrechnungskonto mit amount 0;
--   zweiter Ertrag derselben Muenze trifft dieselbe Position; Rueckgabe = Handles + Post-State (shares).
--   Werte erfunden.
-- ============================================================
BEGIN;
DO $$
DECLARE
    T     DATE := core.fn_today();
    v_set INT;
    v_dep INT;
    v_r   JSONB;
    v_r2  JSONB;
BEGIN
    v_set := (finance.fn_create_account('{"name":"__t_br_set__","account_type":"cash","currency":"EUR","bank":"Bitvavo"}'::jsonb)->>'account_id')::int;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_br_dep__', 'account_type', 'crypto_depot',
                 'currency', 'EUR', 'settlement_id', v_set))->>'account_id')::int;

    v_r := finance.fn_book_reward(v_dep, v_set, NULL, 'BRX', 'BRX', 0.25, T - 3);
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'shares')::numeric <> 0.25
       OR NOT EXISTS (SELECT 1 FROM finance.depot_holdings h WHERE h.id = (v_r->>'holding_id')::int
                      AND h.account_id = v_dep AND h.symbol = 'BRX' AND h.isin IS NULL AND h.currency = 'EUR')
       OR NOT EXISTS (SELECT 1 FROM finance.transactions x WHERE x.id = (v_r->>'transaction_id')::int
                      AND x.account_id = v_set AND x.category::text = 'reward' AND x.amount = 0 AND x.shares = 0.25
                      AND x.transaction_date = T - 3 AND x.description = 'Staking BRX') THEN
        RAISE EXCEPTION 'FAIL [BR1 neue Position + Buchung]: %', v_r; END IF;

    v_r2 := finance.fn_book_reward(v_dep, v_set, NULL, 'BRX', 'BRX', 0.5, T - 2);
    IF (v_r2->>'holding_id')::int <> (v_r->>'holding_id')::int OR (v_r2->>'shares')::numeric <> 0.75
       OR finance.fn_get_balance(v_set) <> 0 THEN
        RAISE EXCEPTION 'FAIL [BR2 dieselbe Position, kein Geld]: %', v_r2; END IF;
    RAISE NOTICE 'PASS [BR1-BR2 fn_book_reward]';
END $$;
ROLLBACK;
