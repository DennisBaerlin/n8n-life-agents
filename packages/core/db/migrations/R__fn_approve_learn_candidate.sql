-- ============================================================
-- agent.fn_approve_learn_candidate(p jsonb) -> jsonb   (Phase C, WS-3)
--   Der owner-gegatete EINZIGE core_contexts-Schreibpfad des Lern-Loops (Orchestrator-Callback learn:ok:<id>).
--   Dispatcht nach target_kind: 'fact' -> agent.fn_set_context_facts (metadata.facts-Merge, validierte
--   Bestands-Route); 'note' -> core.fn_append_context_note (Prosa unter "## Gelernt"). Markiert den
--   Kandidaten 'approved' NUR bei erfolgreichem Write; ein {ok:false} des Ziel-Writes (z. B. Person fehlt
--   im Haushalt, nicht-Knowledge-Kontext) wird durchgereicht, der Kandidat bleibt pending. owner_only-
--   Backstop (agent.fn_sender_is_member) zusaetzlich zum Orchestrator-'Callback owner?'-Gate (Defense-in-Depth).
--   Gelesene p-Keys: { candidate_id, chat_id }. INVOKER, search_path-Pin + REVOKE.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_approve_learn_candidate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog, agent, core
AS $$
DECLARE
    v_cid  bigint := NULLIF(p->>'candidate_id', '')::bigint;
    v_chat text   := p->>'chat_id';
    c      record;
    v_res  jsonb;
BEGIN
    IF agent.fn_sender_is_member(v_chat) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;
    IF v_cid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'candidate_id required');
    END IF;
    SELECT * INTO c FROM agent.guide_learn_candidates WHERE id = v_cid FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'candidate not found');
    END IF;
    IF c.status <> 'pending' THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('candidate already %s', c.status));
    END IF;

    IF c.target_kind = 'fact' THEN
        v_res := agent.fn_set_context_facts(jsonb_build_object(
            'context_name', c.context_name,
            'facts', jsonb_build_object('persons', jsonb_build_array(
                jsonb_build_object('person_id', c.person_slug, c.field, c.proposed_value))),
            'scope', 'household',   -- Lern-Fakten sind persons-foermig = household (Vorfilter fn_facts_context_allowed)
            'chat_id', v_chat));
    ELSE
        v_res := core.fn_append_context_note(jsonb_build_object(
            'context_name', c.context_name, 'note', c.proposed_value, 'chat_id', v_chat));
    END IF;

    IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
        RETURN v_res;   -- Ziel-Write abgelehnt -> Kandidat bleibt pending, Grund durchreichen
    END IF;

    UPDATE agent.guide_learn_candidates SET status = 'approved', approved_at = now() WHERE id = v_cid;
    RETURN jsonb_build_object('ok', true, 'target_kind', c.target_kind, 'context_name', c.context_name, 'write', v_res);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_approve_learn_candidate(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN REVOKE ALL ON FUNCTION agent.fn_approve_learn_candidate(jsonb) FROM context_ro; END IF;
END $$;
