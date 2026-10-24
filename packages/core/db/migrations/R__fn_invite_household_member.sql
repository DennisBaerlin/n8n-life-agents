-- ============================================================
-- fn_invite_household_member (WS-5a — Owner stellt eine Member-Einladung aus -> armt die Challenge)
--   Schritt 1 des Einladungs-Flows: der Owner sagt im Chat "lade meine Tochter Lisa ein". Das Tool
--   tool_invite_household_member (agent.guide) ruft dies NACH dem HITL-Approve. Atomar:
--     1. (Re-)Validierung ueber den geteilten Kern fn_check_household_invite (Owner-Gate +
--        Person existiert & ungepairt) -> TOCTOU-sicher zur Write-Zeit, eine Quelle.
--     2. Einmal-Code generieren (>=8 alphanumerisch = pairing_state-CHECK; md5 = kein pgcrypto noetig).
--     3. fn_arm_pairing_challenge(role, challenge, person_id) armt die Member-Einladung (10-Min-Expiry,
--        superseded aeltere offene Einladungen derselben person_id).
--   Der Owner teilt den zurueckgegebenen Code als Deep-Link t.me/<bot>?start=<code> ausserhalb; das
--   Mitglied loest ihn ein (fn_claim_pairing_challenge -> Stage), der Owner bestaetigt (fn_confirm_pairing).
--   p: { chat_id (Owner-chat), person_name }
--   RUECKGABE: {ok:true, person_id, role, full_name, challenge, expires_at} | {ok:false, reason}
--   Invarianten-Tests: tests/db/core/test_fn_invite_household_member.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_invite_household_member(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chk  JSONB;
    v_pid  TEXT;
    v_role TEXT;
    v_full TEXT;
    v_code TEXT;
    v_arm  JSONB;
BEGIN
    v_chk := agent.fn_check_household_invite(p);
    IF (v_chk->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_chk;          -- Owner-Gate/Person-Check fehlgeschlagen -> freundliches {ok:false}, kein Write
    END IF;
    v_pid := v_chk->>'person_id';
    v_role := v_chk->>'role';
    v_full := v_chk->>'full_name';

    -- Einmal-Code: 16 Hex-Zeichen (~64 bit), erfuellt den >=8-alphanumerisch-CHECK von pairing_state.
    v_code := substr(md5(random()::text || clock_timestamp()::text || v_pid), 1, 16);

    v_arm := agent.fn_arm_pairing_challenge(
                 jsonb_build_object('role', v_role, 'challenge', v_code, 'person_id', v_pid));
    IF (v_arm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_arm;          -- z. B. konkurrierender Arm -> {ok:false, reason}, durchreichen
    END IF;

    RETURN jsonb_build_object('ok', true, 'person_id', v_pid, 'role', v_role,
                              'full_name', v_full, 'challenge', v_code, 'expires_at', v_arm->>'expires_at');
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_invite_household_member(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_invite_household_member(JSONB) FROM context_ro;
    END IF;
END $$;
