-- ============================================================
-- fn_delete_recurring_payment (ATOMIC WRITE) -- Hard-DELETE einer STANDALONE Fehlanlage
--   Nur fuer standalone wiederkehrende Zahlungen (Gehalt/Miete/Abo/Rente). Eine entitaets-besessene
--   recurring_payment (Versicherung/Kredit/Pension/Sparziel/Sparplan) wird NICHT hier geloescht,
--   sondern ueber das set_/close_-Tool der besitzenden Entitaet (sonst broken FK / Cashflow-Leiche).
--   KORRIGIERBAR (kein RAISE -> kein Owner-Alert):
--     - von einer Entitaet besessen -> {ok:false, reason, owner} (Verweis aufs set_/close_-Tool),
--     - >=1 gebuchte Transaktion (recurring_payment_id) -> {ok:false, reason, transaction_count}
--       (RESTRICT; erst die Buchung(en) voiden),
--     - Zubringer (2026-10-27): ein Transfer in das Verrechnungskonto eines aktiven Sparplans oder den Topf eines aktiven
--       Sparziels -> {ok:false, code:'feeds_savings'} ausser confirm_feeds_savings=true (Nutzer bestaetigt ausdruecklich).
--   Eingabe jsonb: recurring_payment_name, confirm_feeds_savings (opt). Resolve findet auch paused (p_active_only=FALSE).
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
    v_target  INT;
    v_feeds   TEXT;
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

    -- Korrigierbar (Livebefund 2026-10-27): ein Dauerauftrag, der das Verrechnungskonto eines aktiven Sparplans oder den
    -- Topf eines aktiven Sparziels fuellt, ist KEIN Duplikat einer Ziel-Rate (der Agent loeschte ihn so). Nur mit
    -- ausdruecklicher Bestaetigung des Nutzers (confirm_feeds_savings=true), dass es ihn nicht mehr gibt.
    SELECT rp.target_account_id INTO v_target FROM finance.recurring_payments rp WHERE rp.id = v_id;
    IF v_target IS NOT NULL AND lower(COALESCE(p->>'confirm_feeds_savings', '')) IS DISTINCT FROM 'true' THEN
        SELECT string_agg(x.what, '; ') INTO v_feeds FROM (
            SELECT 'savings plan "' || sp.name || '" (settlement account)' AS what
              FROM finance.savings_plans sp
              JOIN finance.recurring_payments r ON r.id = finance.fn_recurring_current(sp.recurring_payment_id, current_date)
             WHERE sp.status = 'active' AND r.account_id = v_target
            UNION
            SELECT 'savings goal "' || g.name || '" (savings account)'
              FROM finance.savings_goals g
             WHERE g.status = 'active'
               AND (EXISTS (SELECT 1 FROM finance.savings_goal_account_share s
                             WHERE s.goal_id = g.id AND s.account_id = v_target AND s.share_eur <> 0)
                    OR EXISTS (SELECT 1 FROM finance.recurring_payments gr
                                WHERE gr.id = g.recurring_payment_id AND gr.target_account_id = v_target))) x;
        IF v_feeds IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'feeds_savings',
                'reason', 'This standing transfer feeds ' || v_feeds || ' - it is not a duplicate of a savings goal rate '
                       || 'and keeps that money flowing. Do not delete it. Only if the user explicitly says the transfer '
                       || 'itself no longer exists at the bank, call again with confirm_feeds_savings=true.');
        END IF;
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
