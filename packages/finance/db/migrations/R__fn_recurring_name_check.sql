-- ============================================================
-- fn_recurring_name_check (NAMENSSPERRE NEUER DAUERZAHLUNGEN, Paket DB-ist-das-Gesetz S6)
--   Gerufen NUR von den oeffentlichen fn_create_recurring_payment / fn_create_recurring_transfer — NICHT von der
--   geteilten fn_add_recurring_payment (Versicherung, Kredit, Sparziel, Rente, Sparplan, Split, Reopen legen dort
--   legitim gleichnamige Zeilen an). Praedikat "laeuft gerade" = finance.active_recurring_payments (die eine Quelle).
--   Rueckgabe:
--     {ok:false, code:'duplicate_name', reason, candidates}  laufende FREISTEHENDE Zahlung gleichen Namens
--                                                            (ohne Gross-/Kleinschreibung, fn_name_matches)
--     {ok:true, card_lines:[note]}                           nur eine Entitaets-Zahlung gleichen Namens -> Hinweis auf
--                                                            der Karte (finance.note.similar_recurring_payment), kein Block
--     {ok:true, card_lines:[]}                               frei
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_name_check(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_free  JSONB;
    v_owned JSONB;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'amount', a.amount, 'account_id', a.account_id)
                     ORDER BY a.id) FILTER (WHERE a.owner IS NULL),
           jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'owner', a.owner)
                     ORDER BY a.id) FILTER (WHERE a.owner IS NOT NULL)
    INTO v_free, v_owned
    FROM (SELECT arp.id, arp.name, arp.amount, arp.account_id, finance.fn_recurring_owner(arp.id) AS owner
            FROM finance.active_recurring_payments arp
           WHERE finance.fn_name_matches(arp.name, p_name, FALSE)) a;

    IF v_free IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'duplicate_name',
            'reason', 'A running recurring payment named "' || (v_free->0->>'name') || '" already exists - change it with '
                   || 'tool_set_recurring_payment, or choose a different name if it is really a second payment.',
            'candidates', v_free);
    END IF;
    RETURN jsonb_build_object('ok', true, 'card_lines',
        CASE WHEN v_owned IS NULL THEN '[]'::jsonb
             ELSE jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.similar_recurring_payment',
                                                       'params', jsonb_build_object('name', v_owned->0->>'name'))) END);
END;
$$;
