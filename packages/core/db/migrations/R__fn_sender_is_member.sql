-- ============================================================
-- fn_sender_is_member (read-only Authz-Pradikat — WS-5b owner_only-Backstop)
--   Geteilter DB-Guard: ist der Sender ein POSITIV aufgeloester Nicht-Owner ("Mitglied")?
--   TRUE  nur wenn chat_id NUMERISCH ∧ agent.fn_resolve_sender(chat_id) found:true ∧ role <> 'owner'.
--   FALSE (durchlassen) bei: role='owner' · nicht in family (found:false, anomal/Bootstrap) ·
--          nicht-numerischer chat_id (E2E-Sentinel — der Resolver wird NIE mit ::bigint gerufen) · NULL/leer.
--   Die owner_only-Schreib-fns (fn_advisor_save_section/_publish_plan/fn_set_context_facts) rufen das
--   Pradikat VOR jedem Write und lehnen ein Mitglied mit {ok:false, reason:'owner_only'} ab (RAISE-frei,
--   kein Owner-Alert). Identitats-Quelle = die deterministische, nicht-spoofbare chat_id (nicht LLM-Werte) —
--   spiegelt das tool_invite_household_member-Muster. Konsistent mit dem Gate-Zweig "is_member".
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_sender_is_member(p_chat_id text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sender JSONB;
BEGIN
    -- Numerik-Guard VOR dem ::bigint-Cast (nicht-numerisch = Test/Sentinel -> durchlassen, kein Wurf)
    IF p_chat_id IS NULL OR p_chat_id !~ '^[0-9]+$' THEN
        RETURN false;
    END IF;
    v_sender := agent.fn_resolve_sender(p_chat_id::bigint);
    RETURN COALESCE((v_sender->>'found')::boolean, false)
           AND (v_sender->>'role') IS DISTINCT FROM 'owner';
END;
$$;
