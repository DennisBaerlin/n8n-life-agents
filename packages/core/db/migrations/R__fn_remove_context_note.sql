-- ============================================================
-- core.fn_remove_context_note(p jsonb) -> jsonb   (Phase C, WS-3; NEU — Undo/learn:undo, R5-C)
--   Entfernt die zu einem APPROVED note-Kandidaten gehoerende "## Gelernt"-Zeile aus dem Ziel-Kontext
--   (allowlist-geguardet) UND setzt den Kandidaten auf 'rejected' -> HITL-Reversibilitaet des
--   Prosa-Schreibpfads. Entfernt zeilen-genau (gleiche Normalisierung wie der Append: Bullet-Zeile, die den
--   normalisierten Notiztext UND den Provenienz-Marker "aus Chat" traegt) -> trifft keine fremden Bullets.
--   owner_only-Backstop. Gelesene p-Keys: { candidate_id, chat_id }. INVOKER, search_path-Pin + REVOKE.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_remove_context_note(p jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog, agent, core
AS $$
DECLARE
    v_cid     bigint := NULLIF(p->>'candidate_id', '')::bigint;
    v_ctx     text;
    v_val     text;
    v_kind    text;
    v_status  text;
    v_norm    text;
    v_content text;
    v_kept    text[];
    v_orig_n  int;
BEGIN
    IF agent.fn_sender_is_member(p->>'chat_id') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;
    IF v_cid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'candidate_id required');
    END IF;
    SELECT context_name, proposed_value, target_kind, status
      INTO v_ctx, v_val, v_kind, v_status
    FROM agent.guide_learn_candidates WHERE id = v_cid FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'candidate not found');
    END IF;
    IF v_kind <> 'note' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'candidate is not a note');
    END IF;
    IF v_status <> 'approved' THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('candidate is %s (only approved notes are undoable)', v_status));
    END IF;
    IF NOT core.fn_note_context_allowed(v_ctx) THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('context "%s" is not note-appendable', v_ctx));
    END IF;

    v_norm := lower(regexp_replace(btrim(v_val), '\s+', ' ', 'g'));

    SELECT content INTO v_content FROM agent.core_contexts WHERE name = v_ctx FOR UPDATE;
    v_content := COALESCE(v_content, '');
    v_orig_n  := COALESCE(array_length(string_to_array(v_content, E'\n'), 1), 0);

    SELECT array_agg(ln ORDER BY ord) INTO v_kept
    FROM unnest(string_to_array(v_content, E'\n')) WITH ORDINALITY AS t(ln, ord)
    WHERE NOT (ln LIKE '- %' AND position(v_norm IN lower(ln)) > 0 AND ln ILIKE '%aus Chat%');

    v_content := array_to_string(COALESCE(v_kept, ARRAY[]::text[]), E'\n');

    UPDATE agent.core_contexts SET content = v_content WHERE name = v_ctx;
    UPDATE agent.guide_learn_candidates SET status = 'rejected', rejected_at = now() WHERE id = v_cid;

    RETURN jsonb_build_object('ok', true, 'context_name', v_ctx,
        'removed', (v_orig_n <> COALESCE(array_length(string_to_array(v_content, E'\n'), 1), 0)));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_remove_context_note(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN REVOKE ALL ON FUNCTION core.fn_remove_context_note(jsonb) FROM context_ro; END IF;
END $$;
