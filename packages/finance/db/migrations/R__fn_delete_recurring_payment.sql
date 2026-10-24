-- ============================================================
-- fn_delete_recurring_payment (ATOMIC WRITE) -- Hard-DELETE einer STANDALONE Fehlanlage
--   Nur fuer standalone wiederkehrende Zahlungen (Gehalt/Miete/Abo/Rente). Eine entitaets-besessene
--   recurring_payment (Versicherung/Kredit/Pension/Sparziel/Sparplan) wird NICHT hier geloescht,
--   sondern ueber das set_/close_-Tool der besitzenden Entitaet (sonst broken FK / Cashflow-Leiche).
--   KORRIGIERBAR (kein RAISE -> kein Owner-Alert):
--     - von einer Entitaet besessen -> {ok:false, reason, owner} (Verweis aufs set_/close_-Tool),
--     - >=1 gebuchte Transaktion (recurring_payment_id) -> {ok:false, reason, transaction_count}
--       (RESTRICT; erst die Buchung(en) voiden).
--   Eingabe jsonb: recurring_payment_name. Resolve findet auch paused (p_active_only=FALSE).
--   RUECKGABE: {ok:true, action:'deleted', recurring_payment_id}. RAISE nur bei not-found / mehrdeutig.
--   finance_recurring_payment_skips gehen per ON DELETE CASCADE automatisch mit.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_delete_recurring_payment(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name    TEXT := p->>'recurring_payment_name';
    v_resolve RECORD;
    v_id      INT;
    v_owner   TEXT;
    v_cnt     INT;
BEGIN
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_recurring_payment(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Recurring payment "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple recurring payments match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;
    v_id := v_resolve.id;

    -- Korrigierbar: entitaets-besessen -> {ok:false} (Verweis aufs set_/close_-Tool der Entitaet).
    v_owner := finance.fn_recurring_owner(v_id);
    IF v_owner IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This recurring payment belongs to a ' || v_owner
                   || ' and cannot be deleted standalone. Change or end it via the ' || v_owner || ' tool '
                   || '(set_/close_' || v_owner || ').',
            'owner', v_owner);
    END IF;

    -- Korrigierbar: gebuchte Transaktionen -> {ok:false} (RESTRICT).
    SELECT COUNT(*) INTO v_cnt FROM finance.transactions WHERE recurring_payment_id = v_id;
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This recurring payment has ' || v_cnt || ' booked occurrence(s) and cannot be deleted. '
                   || 'Void the transaction(s) first.', 'transaction_count', v_cnt);
    END IF;

    DELETE FROM finance.recurring_payments WHERE id = v_id;  -- skips per CASCADE

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'recurring_payment_id', v_id);
END;
$$;
