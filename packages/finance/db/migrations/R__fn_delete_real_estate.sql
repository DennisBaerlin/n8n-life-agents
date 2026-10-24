-- ============================================================
-- fn_delete_real_estate (ATOMIC WRITE) -- Hard-DELETE einer Fehlanlage
--   Immobilien haben keine recurring_payment und keine direkten Buchungen; ihre einzige
--   "Historie" sind verknuepfte Kredite (real_estate_id, FK RESTRICT). Daher reines
--   Delete-if-empty (kein Soft-Close-Status -- 'sold' braucht eine Verkaufsbuchung,
--   siehe Backlog sell_real_estate).
--   KORRIGIERBAR (kein RAISE -> kein Owner-Alert):
--     - von >=1 Kredit referenziert -> {ok:false, reason, loan_count}.
--   Eingabe jsonb: real_estate_name.
--   RUECKGABE: {ok:true, action:'deleted', real_estate_id}. RAISE nur fuer echte
--   Ausnahmen (nicht gefunden / mehrdeutig -> vorher aufloesen).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_delete_real_estate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name       TEXT := p->>'real_estate_name';
    v_resolve    RECORD;
    v_re_id      INT;
    v_loan_count INT;
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

    -- Korrigierbar: von Krediten referenziert (FK RESTRICT wuerde sonst hart scheitern).
    SELECT COUNT(*) INTO v_loan_count
    FROM finance.loans WHERE real_estate_id = v_re_id;
    IF v_loan_count > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This property is linked to ' || v_loan_count
                   || ' loan(s) and cannot be deleted. Pay off / unlink the loan(s) first '
                   || '(or sell the property once a sell tool exists).',
            'loan_count', v_loan_count);
    END IF;

    DELETE FROM finance.real_estate WHERE id = v_re_id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'real_estate_id', v_re_id);
END;
$$;
