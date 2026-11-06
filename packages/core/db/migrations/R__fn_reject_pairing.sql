-- ============================================================
-- fn_reject_pairing (WS-5a — Owner lehnt die gestagete Einladung ab -> Stage verwerfen)
--   Schritt 3 (Decline): der Owner tippt ❌ am callback_query. Owner-Auth liegt deterministisch im
--   Orchestrator-Handler VOR diesem Aufruf. Markiert die Zeile als konsumiert (consumed_at) OHNE jede
--   Bindung -> die Member-Identitaet wird NICHT an die Person geheftet. Idempotent (zweites ❌ -> resolved).
--   p: { id }
--   RUECKGABE: {ok:true, person_id, full_name, member_chat_id}   (-> Member „abgelehnt"-Notiz)
--            | {ok:false, resolved:true}     (bereits aufgeloest)
--            | {ok:false, reason}            (nicht gefunden)
--   Invarianten-Tests: tests/db/core/test_fn_pairing_challenge.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_reject_pairing(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id   INT := NULLIF(p->>'id', '')::int;
    v_pid  TEXT;
    v_chat TEXT;
    v_done TIMESTAMPTZ;
    v_name TEXT;
BEGIN
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'pairing id is required');
    END IF;

    SELECT person_id, claimed_chat_id, consumed_at
    INTO v_pid, v_chat, v_done
    FROM agent.pairing_state WHERE id = v_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'pairing request not found');
    END IF;
    IF v_done IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'resolved', true);
    END IF;

    UPDATE agent.pairing_state SET consumed_at = NOW() WHERE id = v_id;

    SELECT NULLIF(trim(concat_ws(' ', pp->>'first_name', pp->>'last_name')), '') INTO v_name
    FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
    WHERE c.name = 'family' AND pp->>'person_id' = v_pid
    LIMIT 1;

    RETURN jsonb_build_object('ok', true, 'person_id', v_pid, 'full_name', v_name, 'member_chat_id', v_chat);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_reject_pairing(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_reject_pairing(JSONB) FROM context_ro;
    END IF;
END $$;
