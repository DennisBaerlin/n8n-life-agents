-- ============================================================
-- fn_add_recurring_payment (INTERNAL HELPER — not tool-facing)
--   Eine Quelle fuer den finance_recurring_payments-INSERT. Wird aus den Entity-Create-/Set-fns
--   (insurance/loan/savings_goal/pension/savings_plan + den set_*-Validity-Splits) UND dem oeffentlichen fn_create_recurring_payment
--   gerufen. Positionale Args (kein jsonb, da nur fn-intern).
--   p_amount ist VORZEICHENBEHAFTET (+ Einnahme / - Ausgabe). monthly_equivalent ist GENERATED.
--   Defaults: p_interval NULL -> 1, p_valid_from NULL -> p_first, p_status NULL -> 'active'.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_add_recurring_payment(
    p_account_id  int,
    p_amount      numeric,
    p_name        text,
    p_interval    smallint,
    p_unit        finance.schedule_unit,
    p_dom         smallint,
    p_first       date,
    p_valid_from  date,
    p_valid_to    date,
    p_status      finance.payment_status,
    p_notes       text
) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_id INT;
BEGIN
    INSERT INTO finance.recurring_payments
        (name, account_id, amount, schedule_interval, schedule_unit, schedule_day_of_month,
         first_payment_date, valid_from, valid_to, status, notes)
    VALUES (
        p_name,
        p_account_id,
        p_amount,
        COALESCE(p_interval, 1),
        p_unit,
        p_dom,
        p_first,
        COALESCE(p_valid_from, p_first),
        p_valid_to,
        COALESCE(p_status, 'active'),
        p_notes
    )
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;
