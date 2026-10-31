-- ============================================================
-- agent.fn_claim_persona_sticker (Sticker vor der Antwort, Bot mit Gesicht 2026-10-30)
--   Die EINE Entscheidung, ob vor einer Antwort ein Persona-Sticker kommt (kein LLM, keine Mehrkosten). Der
--   Orchestrator ruft sie vor der Relay-Kette und nach einer eigenen Persona-Wahl; der Gateway sendet den
--   Sticker '<set>_<ausdruck>' (provisioning/llm_gateway, Ordner packages/core/build/stickers).
--   ZERO-TRUST: re-resolvt den Absender selbst aus p->>'chat_id' (RAISE-freier Cast); das Set ist seine
--   Persona (fehlt -> 'neutral' = Roboter-Set, Owner-Entscheid 2026-10-30).
--   AUSWAHL (hoechstens einer, Prioritaet):
--     yay   — Einrichtung in DIESEM Lauf fertig: Latch onboarding/all_done:<pid> mit last_fired_at >= Laufbeginn
--     top   — Karte DIESES Laufs endgueltig bestaetigt (agent.hitl_pending.approved, opened_at >= Laufbeginn)
--     hmm   — Datei/Foto im Lauf
--     hallo — reiner Gruss (core.fn_smalltalk_kind) ohne Werkzeug-Aufruf
--     event 'persona_chosen' (eigene Wahl, agent.fn_set_person_persona) -> hallo im neuen Set
--   LAUFBEGINN = run_started_at, eine DB-Zeit vom Anfang des Laufs (Resolve sender, clock_timestamp()) -> derselbe
--     Zeitgeber wie opened_at/last_fired_at (nie die Telegram-Uhr message.date; Code-Review 2026-10-30).
--   Nie bei Signal NOFRAME (ernster Moment, Router-Regel 6); lief ein Werkzeug ohne Signal, gilt das als NOFRAME (wie
--     das Router-Gedaechtnis). top/hmm verlangen FRAME. yay/top/hmm verlangen reply_ok (die Antwort ist kein fester
--     Leer-/Fehler-Hinweis) -> nie ein Daumen hoch vor einer Fehlermeldung.
--   BREMSE: core.fn_should_notify('persona_sticker', <pid>, persona.sticker_cooldown_hours) — erst Kandidat, dann
--     Gate (Vertrag der Notify-Schicht). yay + Persona-Wahl umgehen die Pruefung, setzen den Latch aber neu.
--     0 Stunden = keine Bremse. Aus-Schalter persona.stickers_enabled.
--   p: {chat_id, text, tool_called, has_file, signal, reply_ok, run_started_at (timestamptz), event?}
--   RUECKGABE: {ok:true, sticker:'<set>_<ausdruck>'|null}  (nie RAISE -> ein Fehler kostet nur den Sticker)
--   Tests: tests/db/core/test_fn_claim_persona_sticker.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_claim_persona_sticker(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    c_src     constant text := 'persona_sticker';
    v_none    constant jsonb := jsonb_build_object('ok', true, 'sticker', NULL);
    v_chat    bigint;
    v_sender  jsonb;
    v_pid     text;
    v_set     text;
    v_since   timestamptz;
    v_signal  text := upper(btrim(COALESCE(p->>'signal', '')));
    v_expr    text;
    v_bypass  boolean := false;
    v_hours   int;
BEGIN
    IF COALESCE(core.fn_config_get('core', 'persona', 'stickers_enabled'), 'true') <> 'true' THEN
        RETURN v_none;
    END IF;
    BEGIN
        v_chat  := NULLIF(p->>'chat_id', '')::bigint;
        v_since := NULLIF(p->>'run_started_at', '')::timestamptz;
        v_hours := COALESCE(NULLIF(core.fn_config_get('core', 'persona', 'sticker_cooldown_hours'), '')::int, 4);
    EXCEPTION WHEN OTHERS THEN
        RETURN v_none;
    END;
    v_sender := agent.fn_resolve_sender(v_chat);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN v_none;
    END IF;
    v_pid := v_sender->>'person_id';
    v_set := COALESCE(v_sender->>'persona', 'neutral');
    IF NOT EXISTS (SELECT 1 FROM core.ui_personas x WHERE x.code = v_set) THEN
        RETURN v_none;
    END IF;

    IF p->>'event' = 'persona_chosen' THEN
        v_expr := 'hallo';  v_bypass := true;
    ELSIF v_signal = 'NOFRAME' OR (COALESCE((p->>'tool_called')::boolean, false) AND v_signal <> 'FRAME') THEN
        RETURN v_none;
    ELSIF COALESCE((p->>'reply_ok')::boolean, true) IS NOT TRUE AND COALESCE((p->>'tool_called')::boolean, false) THEN
        RETURN v_none;
    ELSIF v_since IS NOT NULL AND EXISTS (
            SELECT 1 FROM core.notification_state n
             WHERE n.source = 'onboarding' AND n.key = 'all_done:' || v_pid
               AND n.state = 'fired' AND n.last_fired_at >= v_since) THEN
        v_expr := 'yay';  v_bypass := true;
    ELSIF v_signal = 'FRAME' AND v_since IS NOT NULL AND EXISTS (
            SELECT 1 FROM agent.hitl_pending h
             WHERE h.chat_id = v_chat AND h.approved IS TRUE AND h.opened_at >= v_since) THEN
        v_expr := 'top';
    ELSIF v_signal = 'FRAME' AND COALESCE((p->>'has_file')::boolean, false) THEN
        v_expr := 'hmm';
    ELSIF COALESCE((p->>'tool_called')::boolean, false) IS NOT TRUE
          AND core.fn_smalltalk_kind(p->>'text') = 'greeting' THEN
        v_expr := 'hallo';
    ELSE
        RETURN v_none;
    END IF;

    IF v_hours > 0 THEN
        IF v_bypass THEN
            PERFORM core.fn_notify_resolve(c_src, v_pid);
        END IF;
        IF NOT core.fn_should_notify(c_src, v_pid, make_interval(hours => v_hours)) THEN
            RETURN v_none;
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'sticker', v_set || '_' || v_expr);
EXCEPTION WHEN OTHERS THEN
    RETURN v_none;
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_claim_persona_sticker(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_claim_persona_sticker(JSONB) FROM context_ro;
    END IF;
END $$;
