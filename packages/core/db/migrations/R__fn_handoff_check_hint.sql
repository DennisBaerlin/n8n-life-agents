-- ============================================================
-- core.fn_handoff_check_hint(p_chk, p_chat_id) — Kandidaten bzw. Optionen einer abgelehnten Vorpruefung als Satz fuer reason
--   Die Berater-Werkzeuge reichen bei einer Ablehnung nur code + reason an das Modell durch; ohne diesen Zusatz kennt der
--   Berater die Antwort-Knoepfe der Rueckfrage nicht. p_chk = Rueckgabe der Paket-Vorpruefung (core.advisors.handoff_check_fn).
--     handoff_ref_ambiguous -> ' Candidates: <label> | <label>.' (Reihenfolge der Paket-fn)
--     handoff_choice_needed -> ' Options: option=<key> (recommended): <Text> (<Grund>); option=<key>: <Text>. …' (empfohlene zuerst;
--                              Text/Grund aus label_key/reason_key mit params, gerendert in der Sprache der Person des Absenders)
--     sonst ''.
--   Konsumenten: agent.fn_advisor_save_section, agent.fn_record_handoff_correction. STABLE, INVOKER.
--   Tests: tests/db/core/test_fn_advisor_save_section_handoffs.sql, tests/db/core/test_fn_record_handoff_correction.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_check_hint(p_chk jsonb, p_chat_id text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_lang text;
    v_out  text;
BEGIN
    IF p_chk->>'code' = 'handoff_ref_ambiguous' AND jsonb_typeof(p_chk->'candidates') = 'array' THEN
        SELECT string_agg(c->>'label', ' | ' ORDER BY o) INTO v_out
          FROM jsonb_array_elements(p_chk->'candidates') WITH ORDINALITY AS x(c, o);
        RETURN COALESCE(' Candidates: ' || v_out || '.', '');
    END IF;
    IF p_chk->>'code' = 'handoff_choice_needed' AND jsonb_typeof(p_chk->'options') = 'array' THEN
        v_lang := agent.fn_person_lang(core.fn_handoff_person(p_chat_id))->>'lang';
        SELECT string_agg('option=' || (x.e->>'key')
                          || CASE WHEN x.e->'recommended' = 'true'::jsonb THEN ' (recommended)' ELSE '' END || ': '
                          || core.fn_ui_text(x.e->>'label_key', v_lang, COALESCE(x.e->'params', '{}'::jsonb))
                          || CASE WHEN COALESCE(x.e->>'reason_key', '') <> ''
                                  THEN ' (' || core.fn_ui_text(x.e->>'reason_key', v_lang, COALESCE(x.e->'params', '{}'::jsonb)) || ')' ELSE '' END,
                          '; ' ORDER BY COALESCE(x.e->'recommended' = 'true'::jsonb, false) DESC, x.o) INTO v_out
          FROM jsonb_array_elements(p_chk->'options') WITH ORDINALITY AS x(e, o);
        RETURN COALESCE(' Options: ' || v_out || '. Save again with option set to the chosen key.', '');
    END IF;
    RETURN '';
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_check_hint(jsonb, text) FROM public;
