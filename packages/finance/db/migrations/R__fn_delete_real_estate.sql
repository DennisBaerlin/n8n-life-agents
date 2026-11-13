-- ============================================================
-- fn_delete_real_estate (ATOMIC WRITE) -- Hard-DELETE einer Fehlanlage
--   Delete-if-empty: Immobilien haben keine recurring_payment und keine direkten Buchungen, ihre
--   Historie sind verknuepfte Kredite und Ruecklagen (real_estate_id, FK RESTRICT). Kein Soft-Close-Status
--   ('sold' braucht eine Verkaufsbuchung, siehe sell_real_estate).
--   Eingabe jsonb: real_estate_name (Pflicht).
--   Rueckgabe: {ok:true, action:'deleted', real_estate_id}.
--   {ok:false} (kein RAISE -> kein Owner-Alert): code 'not_found' (candidates []) / 'ambiguous' (candidates);
--   von >=1 Kredit referenziert -> reason + loan_count;
--   von >=1 Instandhaltungsruecklage referenziert (jeder Status) -> reason + reserve_count.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_delete_real_estate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name       TEXT := p->>'real_estate_name';
    v_resolve    RECORD;
    v_re_id      INT;
    v_loan_count INT;
    v_reserve_count INT;
BEGIN
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_real_estate(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Real estate "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple properties match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;
    v_re_id := v_resolve.id;

    -- Von Krediten referenziert: als Daten statt hartem FK-Fehler.
    SELECT COUNT(*) INTO v_loan_count
    FROM finance.loans WHERE real_estate_id = v_re_id;
    IF v_loan_count > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This property is linked to ' || v_loan_count
                   || ' loan(s) and cannot be deleted. Pay off / unlink the loan(s) first '
                   || '(or sell the property once a sell tool exists).',
            'loan_count', v_loan_count);
    END IF;

    -- Instandhaltungsruecklage(n) verknuepft, jeder Status: auch eine geschlossene behaelt ihre real_estate_id
    -- (Form-CHECK; FK RESTRICT wie bei Krediten).
    SELECT COUNT(*) INTO v_reserve_count
    FROM finance.savings_goals WHERE real_estate_id = v_re_id;
    IF v_reserve_count > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This property has a maintenance reserve (' || v_reserve_count || ' savings goal(s), also closed '
                   || 'ones keep the link) and cannot be deleted. If the property was sold, record the sale with the '
                   || 'sell tool instead.',
            'reserve_count', v_reserve_count);
    END IF;

    DELETE FROM finance.real_estate WHERE id = v_re_id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'real_estate_id', v_re_id);
END;
$$;
