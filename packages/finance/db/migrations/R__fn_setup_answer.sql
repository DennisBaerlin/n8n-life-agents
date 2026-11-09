-- ============================================================
-- fn_setup_answer (WRITE, kein HITL) -- eine Antwort des Nutzers in der Ersteinrichtung speichern
--   Eingabe: chat_id, question_key, answer, amount, item (der offene Punkt laut fn_setup_next, bei current_balance leer).
--   question_key: current_balance (answer = Stand) | confirm_account (yes|no) | Schluessel eines offenen Punkts:
--   answer skip, accept (uebernimmt item.suggested_amount), total|per_share (nach Rueckfrage) oder amount, die Lesart klaert
--   fn_resolve_cost_basis (item.ref_price). Einstand 0 gibt es nicht.
--   Nicht aus der Datei ableitbare Punkte (mixed_currency, position_incomplete, merger_unclear) kennen nur skip.
--   RUECKGABE: {ok:true, saved:true} | {ok:true, saved:false, ask:{key, as_per_share, as_total}} (genau eine Rueckfrage) | {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_answer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_key    TEXT := p->>'question_key';
    v_answer TEXT := lower(btrim(COALESCE(p->>'answer', '')));
    v_item   JSONB := p->'item';
    v_amount NUMERIC;
    v_basis  JSONB;
    v_val    JSONB;
    v_s      finance.setup_session%ROWTYPE;
BEGIN
    SELECT * INTO v_s FROM finance.setup_session
    WHERE chat_id = p->>'chat_id' AND created_at > now() - interval '7 days' ORDER BY updated_at DESC LIMIT 1;
    IF v_s.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'There is no open first-time setup.');
    END IF;

    IF v_key = 'current_balance' THEN
        v_amount := round(finance.fn_parse_numeric_or_null(p->>'answer', true), 2);
        IF v_amount IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'The balance "' || COALESCE(p->>'answer', '') || '" is not a number - ask again.');
        END IF;
        v_val := to_jsonb(v_amount);
    ELSIF v_key = 'confirm_account' THEN
        IF v_answer NOT IN ('yes', 'no') THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'Answer yes or no.');
        END IF;
        IF v_answer = 'yes' THEN
            UPDATE finance.setup_session SET decisions = decisions || '{"account_confirmed":true}'::jsonb, updated_at = now() WHERE id = v_s.id;
        ELSE
            UPDATE finance.setup_session
            SET decisions = decisions || jsonb_build_object('rejected_account', (p->>'account_id')), cash_account_id = NULL, updated_at = now()
            WHERE id = v_s.id;
        END IF;
        RETURN jsonb_build_object('ok', true, 'saved', true);
    ELSE
        IF v_item IS NULL OR v_item->>'key' IS DISTINCT FROM v_key THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'This is not the open question. Call tool_import_setup without an answer to see it.');
        END IF;
        IF v_answer = 'skip' THEN
            v_val := '{"skip":true}'::jsonb;
        ELSIF v_item->>'type' IN ('mixed_currency', 'position_incomplete', 'merger_unclear') THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'This position can only be left out (answer skip) and entered by hand later.');
        ELSIF v_answer = 'accept' AND (v_item->>'suggested_amount')::numeric > 0 THEN
            v_val := jsonb_build_object('amount', (v_item->>'suggested_amount')::numeric);
        ELSE
            v_amount := finance.fn_parse_numeric_or_null(p->>'amount', true);
            IF v_amount IS NULL OR v_amount <= 0 THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'A cost above 0 is needed, or leave the position out (answer skip).');
            END IF;
            IF v_answer = 'per_share' THEN
                v_val := jsonb_build_object('amount', round(v_amount * (v_item->>'shares')::numeric, 2));
            ELSIF v_answer = 'total' THEN
                v_val := jsonb_build_object('amount', round(v_amount, 2));
            ELSE
                v_basis := finance.fn_resolve_cost_basis(v_amount, (v_item->>'shares')::numeric, (v_item->>'ref_price')::numeric);
                IF v_basis->>'kind' = 'ask' THEN
                    RETURN jsonb_build_object('ok', true, 'saved', false, 'ask', jsonb_build_object('key', v_key,
                        'as_per_share', v_basis->'as_per_share', 'as_total', v_basis->'as_total'),
                        'say', 'Ask once whether the amount is per unit or in total, then call tool_import_setup with the same amount and answer per_share or total.');
                END IF;
                v_val := jsonb_build_object('amount', (v_basis->>'cost_total')::numeric);
            END IF;
        END IF;
    END IF;

    UPDATE finance.setup_session SET decisions = decisions || jsonb_build_object(v_key, v_val), updated_at = now() WHERE id = v_s.id;
    RETURN jsonb_build_object('ok', true, 'saved', true);
END;
$$;
