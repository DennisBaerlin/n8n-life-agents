-- ============================================================
-- fn_goal_transfer_choice (READ HELPER — Livebefund 2026-10-27)
--   Die EINE Entscheidung "bestehender Dauerauftrag in den Topf einer neuen Ziel-Rate" fuer fn_savings_goal_funding
--   (Anlegen + Import-Karte) und fn_set_savings_goal (Rate nachtraeglich starten): Kandidaten aus
--   fn_goal_transfer_candidates(p_pot, p_debit), dann je Antwort p_replace:
--     NULL  + Kandidaten -> {ok:false, code:'existing_transfer', transfers, reason} (nie loeschen, Nutzer fragen)
--     false              -> {ok:true, transfer:null} (zusaetzliche Rate)
--     true  + genau einer, monatlich -> {ok:true, transfer:<Kandidat>} (die Ziel-Rate fuehrt ihn fort)
--     true  + keiner -> {ok:false}; true + mehrere -> {ok:false, code:'existing_transfer'} (Abbuchungskonto nennen);
--     true  + nicht monatlich -> {ok:false, code:'transfer_not_monthly'}
--   Keine Kandidaten und keine Antwort -> {ok:true, transfer:null}.
--   plpgsql (late-bound, Kandidaten-fn sortiert spaeter). Schreibt nie.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_transfer_choice(p_pot int, p_debit int, p_replace boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cands JSONB;
    v_old   JSONB;
BEGIN
    IF p_replace IS FALSE THEN
        RETURN jsonb_build_object('ok', true, 'transfer', NULL);
    END IF;
    v_cands := finance.fn_goal_transfer_candidates(p_pot, p_debit);
    IF jsonb_array_length(v_cands) = 0 THEN
        IF p_replace THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'There is no standing transfer into this savings account to continue - leave replace_transfer empty.');
        END IF;
        RETURN jsonb_build_object('ok', true, 'transfer', NULL);
    END IF;
    IF p_replace IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'existing_transfer', 'transfers', v_cands,
            'reason', 'A standing transfer already pays into this savings account: '
                   || (SELECT string_agg('"' || (e->>'name') || '" (' || to_char((e->>'amount')::numeric, 'FM999999990D00')
                                         || ' ' || (e->>'currency') || ', ' || (e->>'rhythm') || ', next on '
                                         || COALESCE(e->>'next_due', '-') || ')', '; ')
                       FROM jsonb_array_elements(v_cands) e)
                   || '. Do NOT delete it. Ask the user whether it IS the savings rate of this goal: yes -> call again '
                   || 'with replace_transfer=true (the goal continues it on the same day, it ends then, nothing is '
                   || 'counted twice); no, the goal rate comes on top -> replace_transfer=false.');
    END IF;
    IF jsonb_array_length(v_cands) > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'existing_transfer', 'transfers', v_cands,
            'reason', 'Several standing transfers pay into this savings account - name the debit account '
                   || '(account_name) of the one the goal continues.');
    END IF;
    v_old := v_cands->0;
    IF (v_old->>'replaceable')::boolean IS DISTINCT FROM true OR v_old->>'next_due' IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'transfer_not_monthly',
            'reason', 'The standing transfer "' || (v_old->>'name') || '" runs ' || (v_old->>'rhythm')
                   || ' - a savings goal rate is monthly, so it cannot continue it. Ask the user whether the goal '
                   || 'rate comes on top (replace_transfer=false) or to change the transfer first.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'transfer', v_old);
END;
$$;
