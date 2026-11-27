-- ============================================================
-- agent.fn_stash_hitl_note(p) — Text bei offener Bestaetigungs-Karte merken (WRITE)
--   Solange eine Gate-Karte offen ist, erreicht eine Textnachricht sie nicht (der Orchestrator antwortet mit festem Hinweis).
--   Der Orchestrator merkt den Text hier an allen noch nicht freigegebenen eigenen Zeilen des Chats (agent.hitl_pending:
--   own_card, released_at NULL, nicht abgelaufen); mehrere Texte werden mit Zeilenumbruch angehaengt, zusammen hoechstens
--   1000 Zeichen (der Rest entfaellt). Nach dem Abbrechen gibt agent.fn_take_hitl_note ihn dem Agenten mit.
--   Eingabe p: {chat_id (Telegram-Zahl), text}. Rueckgabe {ok:true, stored: Anzahl Zeilen, entry} | {ok:false, reason}. Nie RAISE.
--   entry = die Person des Chats (core.fn_handoff_person) hat einen frisch beanspruchten vereinbarten Eintrag (working, claimed_at
--   juenger als advisor.handoff_claim_ttl_minutes): die offene Karte gehoert zum Eintragen, geaendert wird dort nichts (der
--   Orchestrator verweist auf das Plan-Gespraech, Build-ToolCancelled sagt dem Modell dasselbe).
--   Familie: agent.fn_take_hitl_note(p) {execution_id, approved} -> {note: text|null}: liest und leert den Text an den Zeilen
--     der Execution; bei approved = true wird er nur geleert (die Karte galt, der Wunsch ist ueberholt). Nie RAISE (laeuft im
--     Gate neben agent.fn_set_hitl_pending_declined).
--   VOLATILE, INVOKER (Host-Cred), search_path gepinnt.
--   Tests: tests/db/core/test_fn_hitl_note.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_stash_hitl_note(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat text := COALESCE(p->>'chat_id', '');
    v_text text := btrim(COALESCE(p->>'text', ''));
    v_n    int;
    v_ttl  int := core.fn_handoff_claim_ttl();
BEGIN
    IF v_chat !~ '^-?[0-9]{1,18}$' OR v_text = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'chat_id and text are required');
    END IF;
    UPDATE agent.hitl_pending h
       SET note = left(concat_ws(E'\n', h.note, v_text), 1000)
     WHERE h.chat_id = v_chat::bigint AND h.own_card AND h.released_at IS NULL AND h.expires_at > now();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'stored', v_n, 'entry', EXISTS (
        SELECT 1 FROM agent.handoff_tasks t
         WHERE t.person_id = core.fn_handoff_person(v_chat) AND t.status = 'working'
           AND t.claimed_at > now() - make_interval(mins => v_ttl)));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error');
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_stash_hitl_note(jsonb) FROM public;

CREATE OR REPLACE FUNCTION agent.fn_take_hitl_note(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_note text;
BEGIN
    WITH old AS (
        SELECT h.chat_id, h.execution_id, h.note FROM agent.hitl_pending h
         WHERE h.execution_id = COALESCE(p->>'execution_id', '') AND h.note IS NOT NULL
         FOR UPDATE)
    UPDATE agent.hitl_pending h SET note = NULL
      FROM old WHERE h.chat_id = old.chat_id AND h.execution_id = old.execution_id
    RETURNING old.note INTO v_note;
    RETURN jsonb_build_object('note', CASE WHEN COALESCE(NULLIF(p->>'approved', '')::boolean, false) THEN NULL ELSE v_note END);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('note', NULL);
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_take_hitl_note(jsonb) FROM public;
