-- ============================================================
-- fn_create_hitl_pending (Karte-offen-Sperre, Fix C)
--   Das HITL-Gate ruft sie direkt VOR jedem sendAndWait: Zeile (Ursprungs-Chat, execution, own_card) mit
--   expires_at = now() + ttl. Raeumt vorher abgelaufene Zeilen weg; erneutes Anlegen derselben
--   (chat, execution) setzt die Zeile zurueck (Upsert). Nicht-numerische chat_id (Test-Sentinel) -> keine Zeile.
--   own_card (Default true) = die Karte liegt im Ursprungs-Chat; false = Freigabe durch jemand anderen.
--   Laeuft im Chat eine "Bot denkt nach"-Schleife mit offenem Draft-Fenster (agent.thinking_lease.drafting_until),
--   wartet sie es ab (<= 1 s) -> kein "Thinking..." nach der Karte.
--   Fehlende execution_id/ttl_minutes = Bau-Fehler des Aufrufers -> RAISE (nicht nutzerkorrigierbar).
--   p: { chat_id, execution_id, ttl_minutes, own_card? }
--   RUECKGABE: {ok:true, expires_at} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_hitl_pending.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_create_hitl_pending(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat bigint;
    v_exec text := NULLIF(trim(p->>'execution_id'), '');
    v_ttl  int;
    v_own  boolean := COALESCE(NULLIF(p->>'own_card', '')::boolean, true);
    v_exp  timestamptz;
    v_wait numeric;
BEGIN
    IF v_exec IS NULL THEN
        RAISE EXCEPTION 'fn_create_hitl_pending: execution_id is required';
    END IF;
    v_ttl := NULLIF(p->>'ttl_minutes', '')::int;
    IF v_ttl IS NULL OR v_ttl <= 0 THEN
        RAISE EXCEPTION 'fn_create_hitl_pending: ttl_minutes must be a positive integer';
    END IF;
    IF COALESCE(p->>'chat_id', '') !~ '^-?[0-9]+$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'chat_id must be numeric');
    END IF;
    v_chat := (p->>'chat_id')::bigint;

    DELETE FROM agent.hitl_pending WHERE expires_at <= now();

    -- "Bot denkt nach" (agent.thinking_lease): ein evtl. unterwegs befindlicher Draft dieses Chats muss VOR der Karte
    -- ankommen -> sein Fenster abwarten (<= 1 s). Erst die Schalter-Zeilen sperren: ordnet gegen fn_claim_thinking_draft
    -- (dort erst sperren, dann Karte pruefen) -> ein spaeterer Claim sieht die Karte und pausiert.
    PERFORM 1 FROM agent.thinking_lease WHERE chat_id = v_chat FOR UPDATE;
    -- Kein LEAST um den Ausdruck: LEAST ignoriert NULL (kein Schalter) und lieferte dann 1 s statt 0.
    SELECT extract(epoch FROM max(drafting_until) - clock_timestamp()) INTO v_wait
      FROM agent.thinking_lease WHERE chat_id = v_chat;
    IF v_wait > 0 THEN
        PERFORM pg_sleep(LEAST(1.0, v_wait));
    END IF;

    INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, expires_at)
    VALUES (v_chat, v_exec, v_own, now() + make_interval(mins => v_ttl))
    ON CONFLICT (chat_id, execution_id) DO UPDATE
        SET own_card = EXCLUDED.own_card, opened_at = now(), released_at = NULL, expires_at = EXCLUDED.expires_at
    RETURNING expires_at INTO v_exp;

    RETURN jsonb_build_object('ok', true, 'expires_at', v_exp);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_create_hitl_pending(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_create_hitl_pending(JSONB) FROM context_ro;
    END IF;
END $$;
