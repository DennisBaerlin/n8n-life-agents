-- ============================================================
-- fn_claim_pairing_challenge (WS-5a — Member loest die Einladung ein, STAGT [bindet NICHT])
--   Schritt 2 des Einladungs-Flows: das Mitglied tippt den Deep-Link/`/start <code>`. Anders als der
--   Owner-Bootstrap (fn_consume bindet sofort) wird hier NICHT gebunden — der Code wird gegen eine offene
--   MEMBER-Einladung (person_id IS NOT NULL, role <> 'owner') gematcht und der live-Member (uid + chat)
--   in die Zeile GESTAGED (claimed_*). Erst die Owner-Bestaetigung (fn_confirm_pairing via callback_query)
--   committet die Bindung. Race-fest wie fn_consume (FOR UPDATE SKIP LOCKED + Match-Bedingungen ZUSAETZLICH
--   im aeusseren WHERE -> READ-COMMITTED-Recheck).
--   p: { challenge, telegram_user_id (live Member-from.id), chat_id (Member-Chat) }
--   RUECKGABE:
--     {ok:true,  staged:true, id, person_id, role, full_name, member_chat_id}  -> Owner-Notify mit Buttons
--     {ok:false, staged:false, pending:true}   -> Code bereits eingeloest (Owner-Bestaetigung offen)
--     {ok:false, staged:false}                 -> kein offener Member-Code (Owner-Code/ungueltig/abgelaufen)
--                                                 -> der Orchestrator faellt auf den Owner-/Invalid-Pfad
--   Owner-Codes (person_id NULL) matchen hier NIE -> bleiben dem fn_consume-Pfad vorbehalten.
--   WS-5d: eine in agent.access_blocks gesperrte uid wird VOR dem Stagen abgewiesen ({staged:false,blocked}).
--   Textkatalog Phase B: p.language_code (Telegram from.language_code, roh) -> language_hint (normalisiert per
--   agent.fn_normalize_language, sonst NULL) = nur ein VORSCHLAG fuer den Sprach-Picker nach dem Confirm, nie in family.
--   Invarianten-Tests: tests/db/core/test_fn_pairing_challenge.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_claim_pairing_challenge(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chal TEXT   := trim(COALESCE(p->>'challenge', ''));
    v_uid  BIGINT;
    v_chat TEXT   := p->>'chat_id';
    v_id   INT;
    v_pid  TEXT;
    v_role TEXT;
    v_name TEXT;
BEGIN
    IF COALESCE(p->>'telegram_user_id', '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'staged', false,
                                  'reason', 'telegram_user_id (live member id) is required');
    END IF;
    v_uid := (p->>'telegram_user_id')::bigint;
    IF COALESCE(v_chat, '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'staged', false, 'reason', 'member chat_id is required');
    END IF;

    -- WS-5d: gesperrte uid kann sich auch mit gueltigem Member-Code NICHT verbinden (staerkere Sperre).
    IF agent.fn_is_blocked(v_uid) THEN
        RETURN jsonb_build_object('ok', false, 'staged', false, 'blocked', true);
    END IF;

    -- Stagen (race-fest): EINE offene Member-Einladung zum Code, noch nicht eingeloest (claimed_at IS NULL),
    -- nicht abgelaufen. person_id IS NOT NULL + role<>'owner' grenzt Owner-Bootstrap-Challenges aus.
    UPDATE agent.pairing_state
    SET claimed_uid = v_uid, claimed_chat_id = v_chat, claimed_at = NOW(),
        language_hint = agent.fn_normalize_language(p->>'language_code')   -- nur Vorschlag, nie in family
    WHERE id = (SELECT id FROM agent.pairing_state
                WHERE challenge = v_chal AND person_id IS NOT NULL AND role <> 'owner'
                  AND consumed_at IS NULL AND claimed_at IS NULL AND expires_at > NOW()
                ORDER BY id DESC LIMIT 1
                FOR UPDATE SKIP LOCKED)
      AND consumed_at IS NULL AND claimed_at IS NULL AND expires_at > NOW()
    RETURNING id, person_id, role INTO v_id, v_pid, v_role;

    IF v_id IS NULL THEN
        -- Schon gestaged (Mitglied hat den Code bereits eingeloest, Owner-Bestaetigung offen)?
        IF EXISTS (SELECT 1 FROM agent.pairing_state
                   WHERE challenge = v_chal AND claimed_uid = v_uid AND consumed_at IS NULL) THEN
            RETURN jsonb_build_object('ok', false, 'staged', false, 'pending', true);
        END IF;
        RETURN jsonb_build_object('ok', false, 'staged', false);
    END IF;

    SELECT NULLIF(trim(concat_ws(' ', pp->>'first_name', pp->>'last_name')), '') INTO v_name
    FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
    WHERE c.name = 'family' AND pp->>'person_id' = v_pid
    LIMIT 1;

    RETURN jsonb_build_object('ok', true, 'staged', true, 'id', v_id, 'person_id', v_pid,
                              'role', v_role, 'full_name', v_name, 'member_chat_id', v_chat);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_claim_pairing_challenge(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_claim_pairing_challenge(JSONB) FROM context_ro;
    END IF;
END $$;
