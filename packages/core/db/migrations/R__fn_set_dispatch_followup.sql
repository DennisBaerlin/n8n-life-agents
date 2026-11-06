-- ============================================================
-- agent.fn_set_dispatch_followup(p) — Folge-Bindung nach einem Knopf-Tipp setzen (2026-10-28)
--   Ein Knopf startet einen Agenten am Router vorbei (Onboarding-Abschnitt, Haushalt, Plan-Knopf, Plan erklaeren/Wunsch);
--   NACH dem erfolgreichen Relay seiner Antwort merkt der Orchestrator sich hier, welcher Agent gefragt hat. Die naechste
--   Text-Nachricht dieses Chats liest den Hinweis einmalig (agent.fn_take_dispatch_followup) und reicht ihn dem Router als
--   followup_agent. Eine Zeile je Chat, last write wins (ein neuer Knopf ueberschreibt). Muster "aktiver Handler je Chat"
--   (arch-challenge 2026-10-28, Rasa active_loop / PTB ConversationHandler).
--   p: { chat_id (nur Privatchat, numerisch positiv), agent ('agent.<name>', build-fix aus dem Arm, nie LLM) }
--   RUECKGABE: {ok:true} | {ok:false, reason} (ungueltig). Nie RAISE (Komfort; ein Fehler darf den Relay nie stoeren).
--   Tests: tests/db/core/test_fn_dispatch_followup.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_dispatch_followup(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat  text := COALESCE(p->>'chat_id', '');
    v_agent text := COALESCE(p->>'agent', '');
BEGIN
    IF v_chat !~ '^[0-9]{1,18}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'chat_id must be a private chat id');
    END IF;
    IF v_agent !~ '^agent\.[a-z][a-z0-9_]*$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'agent must be agent.<name>');
    END IF;
    INSERT INTO agent.dispatch_followup (chat_id, agent, set_at) VALUES (v_chat, v_agent, now())
    ON CONFLICT (chat_id) DO UPDATE SET agent = EXCLUDED.agent, set_at = EXCLUDED.set_at;
    RETURN jsonb_build_object('ok', true);
END;
$$;
