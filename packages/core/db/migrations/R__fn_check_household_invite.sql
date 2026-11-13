-- ============================================================
-- fn_check_household_invite (Einladungs-Validierung, READ, kein Write)
--   Pre-Gate-Pruefung des tool_invite_household_member-Tools (agent.guide): laeuft vor dem HITL-Gate
--   und vor jedem pairing_state-Write. Deterministische Pruefungen:
--     1. Owner-Gate: nur der gepairte Haushalts-Owner darf einladen. Die Sender-Identitaet kommt
--        aus der Telegram-chat_id (Privatchat: chat.id == from.id), nie aus $fromAI.
--        fn_resolve_sender(uid).role muss 'owner' sein.
--     1b. Bot-Name bekannt (core.fn_app_bot_username), sonst keine Einladung.
--     2. Ziel-Person: existiert genau eine family-Person zum Namen (gleiche Match-Logik wie
--        core.fn_resolve_person: first/last/voll/Alias, case-insensitiv), ist sie kein Owner und
--        noch ungepairt (keine telegram_user_id) -> einladbar.
--   Eingabe p: { chat_id (Telegram-chat des Aufrufers, numerisch), person_name }, beide Pflicht.
--   Rueckgabe: {ok:true, person_id, role, full_name} | {ok:false, reason}; reason u. a. "chat_id is required",
--   "only the household owner can issue member invitations", "person_name is required", Name unbekannt/mehrdeutig,
--   "the owner cannot be invited as a member", "... is already paired to a Telegram account".
--   Wird auch von fn_invite_household_member (Write-Pfad) als gemeinsamer Validierungs-Kern gerufen.
--   Lesepfad unter der Haupt-Credential (agent direkt erreichbar).
--   Invarianten-Tests: tests/db/core/test_fn_invite_household_member.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_check_household_invite(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_chat   TEXT    := NULLIF(p->>'chat_id', '');
    v_uid    BIGINT;
    v_name   TEXT    := lower(trim(COALESCE(p->>'person_name', '')));
    v_sender JSONB;
    v_count  INT;
    v_pid    TEXT;
    v_role   TEXT;
    v_full   TEXT;
    v_paired BOOLEAN;
BEGIN
    IF v_chat IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'chat_id is required');
    END IF;
    BEGIN
        v_uid := v_chat::bigint;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'chat_id must be numeric');
    END;

    -- Owner-Gate (deterministisch, nicht vom LLM entschieden).
    v_sender := agent.fn_resolve_sender(v_uid);
    IF (v_sender->>'found')::boolean IS DISTINCT FROM true OR v_sender->>'role' <> 'owner' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'only the household owner can issue member invitations');
    END IF;

    -- Ohne echten Bot-Namen wuerde der Link auf einen fremden Bot zeigen.
    IF core.fn_app_bot_username() IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'the bot name is not known yet, so no invitation link can be made. Tell the owner to run lifeagents update and try again.');
    END IF;

    IF v_name = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'person_name is required');
    END IF;

    -- Ziel-Person aufloesen (Anzahl + Rolle + ob bereits eine numerische Identitaet gebunden ist).
    SELECT COUNT(*),
           MIN(pp->>'person_id'),
           MIN(pp->>'role'),
           MIN((pp->>'first_name') || ' ' || (pp->>'last_name')),
           bool_or((pp ? 'telegram_user_id') AND jsonb_typeof(pp->'telegram_user_id') <> 'null')
      INTO v_count, v_pid, v_role, v_full, v_paired
    FROM agent.core_contexts c,
         jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family'
      AND (
            lower(pp->>'first_name') = v_name
         OR lower(pp->>'last_name')  = v_name
         OR lower((pp->>'first_name') || ' ' || (pp->>'last_name')) = v_name
         OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(pp->'aliases', '[]'::jsonb)) a
                    WHERE lower(a) = v_name)
      );

    IF COALESCE(v_count, 0) = 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('no household member matches "%s" (capture them via onboarding first)', p->>'person_name'));
    ELSIF v_count > 1 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('"%s" is ambiguous (%s matches); use a more specific name', p->>'person_name', v_count));
    END IF;

    IF v_role = 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'the owner cannot be invited as a member');
    END IF;
    IF v_paired THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('%s is already paired to a Telegram account', v_full));
    END IF;

    RETURN jsonb_build_object('ok', true, 'person_id', v_pid, 'role', v_role, 'full_name', v_full);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_check_household_invite(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_check_household_invite(JSONB) FROM context_ro;
    END IF;
END $$;
