-- ============================================================
-- test_savings_plans_name_uq -- UNIQUE (lower(name)) auf finance.savings_plans ist das Gesetz
--   Zwei Sparplaene mit gleichem Namen (Gross-/Kleinschreibung egal) -> unique_violation, auch depotuebergreifend.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_cash   INT;
    v_depot  INT;
    v_depot2 INT;
    v_rp1    INT;
    v_rp2    INT;
    v_rp3    INT;
    v_hit    BOOLEAN := false;
BEGIN
    v_cash   := (finance.fn_create_account(jsonb_build_object('name', '__t_sn_cash__', 'account_type', 'cash', 'currency', 'EUR'))->>'account_id')::int;
    v_depot  := (finance.fn_create_account(jsonb_build_object('name', '__t_sn_depot1__', 'account_type', 'stocks_depot', 'currency', 'EUR', 'settlement_id', v_cash))->>'account_id')::int;
    v_depot2 := (finance.fn_create_account(jsonb_build_object('name', '__t_sn_depot2__', 'account_type', 'stocks_depot', 'currency', 'EUR', 'settlement_id', v_cash))->>'account_id')::int;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
        VALUES ('__t_sn_rp1__', v_cash, -10, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp1;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
        VALUES ('__t_sn_rp2__', v_cash, -10, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp2;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
        VALUES ('__t_sn_rp3__', v_cash, -10, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp3;

    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__t_sn_Plan Eins__', v_depot, 'ZZP', 'ZZ Plan', v_rp1);

    BEGIN
        INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
        VALUES ('__T_SN_PLAN EINS__', v_depot2, 'ZZQ', 'ZZ Plan Zwei', v_rp2);
    EXCEPTION WHEN unique_violation THEN v_hit := SQLERRM LIKE '%finance_savings_plans_name_uq%'; END;
    IF NOT v_hit THEN RAISE EXCEPTION 'FAIL [name_uq]: zweiter Sparplan mit gleichem Namen (andere Schreibweise, anderes Depot) akzeptiert'; END IF;
    RAISE NOTICE 'PASS [name_uq]: gleicher Name -> unique_violation';

    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__t_sn_Plan Zwei__', v_depot, 'ZZR', 'ZZ Plan Drei', v_rp3);
    RAISE NOTICE 'PASS [anderer Name]: anderer Name erlaubt';
END $$;
ROLLBACK;
