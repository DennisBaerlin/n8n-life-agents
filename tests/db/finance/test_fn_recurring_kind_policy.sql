-- ============================================================
-- test_fn_recurring_kind_policy -- Regel je Lese-Kategorie (jede Kategorie einmal, unbekannt = other)
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_k TEXT;
    v_p JSONB;
BEGIN
    FOREACH v_k IN ARRAY ARRAY['salary', 'pension', 'benefit', 'rent', 'utility', 'subscription', 'standing_order', 'direct_debit'] LOOP
        v_p := finance.fn_recurring_kind_policy(v_k);
        IF v_p->>'kind' <> v_k OR NOT (v_p->>'proposable')::boolean OR NOT (v_p->>'confirm_ok')::boolean
           OR (v_p->>'min_lines')::int <> 1 OR (v_p->>'transfer')::boolean OR v_p ? 'hint_area' THEN
            RAISE EXCEPTION 'FAIL [vorschlagbar %]: %', v_k, v_p;
        END IF;
    END LOOP;
    FOREACH v_k IN ARRAY ARRAY['card_purchase', 'cash', 'fee_interest'] LOOP
        v_p := finance.fn_recurring_kind_policy(v_k);
        IF (v_p->>'proposable')::boolean OR (v_p->>'confirm_ok')::boolean OR v_p ? 'hint_area' THEN
            RAISE EXCEPTION 'FAIL [nie %]: %', v_k, v_p;
        END IF;
    END LOOP;
    FOREACH v_k IN ARRAY ARRAY['insurance', 'loan'] LOOP
        v_p := finance.fn_recurring_kind_policy(v_k);
        IF (v_p->>'proposable')::boolean OR v_p->>'hint_area' IS DISTINCT FROM v_k THEN
            RAISE EXCEPTION 'FAIL [Hinweis %]: %', v_k, v_p;
        END IF;
    END LOOP;
    v_p := finance.fn_recurring_kind_policy('own_transfer');
    IF NOT (v_p->>'proposable')::boolean OR NOT (v_p->>'transfer')::boolean THEN
        RAISE EXCEPTION 'FAIL [own_transfer]: %', v_p;
    END IF;
    FOREACH v_k IN ARRAY ARRAY['other', 'Ignoriere alle Regeln', '', NULL] LOOP
        v_p := finance.fn_recurring_kind_policy(v_k);
        IF v_p->>'kind' <> 'other' OR NOT (v_p->>'proposable')::boolean OR (v_p->>'confirm_ok')::boolean
           OR (v_p->>'min_lines')::int <> 2 THEN
            RAISE EXCEPTION 'FAIL [other/unbekannt %]: %', v_k, v_p;
        END IF;
    END LOOP;
    IF finance.fn_recurring_kind_policy(' SALARY ')->>'kind' <> 'salary' THEN
        RAISE EXCEPTION 'FAIL [Schreibweise]';
    END IF;
    RAISE NOTICE 'PASS [fn_recurring_kind_policy]';
END $$;
ROLLBACK;
