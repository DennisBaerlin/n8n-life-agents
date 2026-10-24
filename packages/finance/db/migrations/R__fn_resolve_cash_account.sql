-- ============================================================
-- fn_resolve_cash_account (KONTONAME -> id fuer Geldbewegungen zwischen eigenen Konten)
--   Loest einen Kontonamen unter den aktiven cash-/Festgeld-Konten auf (fn_resolve_account: erst exakt, dann ohne
--   Gross-/Kleinschreibung). Rueckgabe {ok:true, id} | {ok:false, code:'not_found'|'ambiguous', reason, candidates};
--   ein Depot-Name bekommt den Verweis auf die Depot-Reservierung (tool_book_savings_reservation), weil Depot-Anteile
--   einer Reserve ueber das Journal laufen, nicht ueber eine Geldbewegung.
--   Konsument: fn_book_savings_goal_transfer (das Tool reicht Namen durch statt eigener Resolve-Knoten).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_cash_account(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_res RECORD;
BEGIN
    SELECT r.id, r.hit_count, r.candidates INTO v_res
    FROM finance.fn_resolve_account(p_name, ARRAY['cash', 'fixed_deposit'], TRUE) r;
    IF v_res.hit_count = 1 THEN
        RETURN jsonb_build_object('ok', true, 'id', v_res.id);
    END IF;
    IF v_res.hit_count = 0 AND EXISTS (SELECT 1 FROM finance.fn_resolve_account(p_name, ARRAY['stocks_depot', 'crypto_depot'], TRUE) d
                                       WHERE d.hit_count = 1) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'depot_not_allowed',
            'reason', '"' || p_name || '" is a depot - a depot share of a savings goal is recorded with tool_book_savings_reservation (a reservation), not as a money movement.');
    END IF;
    RETURN jsonb_build_object('ok', false,
        'code', CASE WHEN v_res.hit_count = 0 THEN 'not_found' ELSE 'ambiguous' END,
        'reason', CASE WHEN v_res.hit_count = 0 THEN 'No active cash or fixed-deposit account named "' || COALESCE(p_name, '') || '" - ask the user which account.'
                       ELSE 'Several accounts match "' || p_name || '" - ask the user which one (candidates).' END,
        'candidates', v_res.candidates);
END;
$$;
