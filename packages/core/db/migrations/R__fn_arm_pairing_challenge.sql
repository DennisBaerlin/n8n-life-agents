-- ============================================================
-- fn_arm_pairing_challenge (Multi-User-Pairing — Einmal-Code armieren)
--   Schreibt die Pairing-Challenge fuer eine Telegram-Identitaet in agent.pairing_state
--   (10-Min-Expiry). Dasselbe "ein Ziel = eine offene Challenge"-Muster wie das fruehere
--   fn_arm_import_challenge (Phase 4b via V005 retired): offene aeltere werden still konsumiert,
--   ergaenzt um role + den Owner-Bootstrap-Guard.
--   p: { chat_id?, telegram_user_id?, role, challenge }
--      chat_id           Member-Knock: der knockende Chat; Owner-Bootstrap (CLI): weglassen (NULL)
--      telegram_user_id  Member: bekannte from.id (bindet den Code an die Identitaet); Owner: NULL
--      role              owner|partner|child — wird bei Erfolg in die Person gemergt
--      challenge         >=8 alphanum Code (Entropie-Boden auch als CHECK; OWASP: <64 bit ⟹ Lockout)
--   GESETZE:
--      - owner-no-rearm: existiert in den family-Facts bereits ein GEPAIRTER Owner (role=owner MIT
--        gesetzter telegram_user_id), wird ein erneutes Owner-Arm abgelehnt ({ok:false}) — der
--        etablierte Owner ist Einmal-Bootstrap; ein Re-Arm braucht CLI-Zugriff (Owner aus family
--        entfernen). Das noch UNVERKNUEPFTE Owner-Skelett (role=owner, telegram_user_id NULL) blockt
--        NICHT: der Zwei-Stufen-Bootstrap (Phase 4) seedet das Skelett, BEVOR der Owner seinen Code
--        eintippt — fn_consume hat sonst keine Person zum Mergen. Struktureller Race-Backstop:
--        Partial-UNIQUE pairing_state_one_open_owner (packages/core/db/agent.pairing_init.sql).
--      - Supersede: offene Challenges desselben Ziels (gleicher chat_id ODER gleiche
--        telegram_user_id ODER — bei role=owner — jede offene Owner-Challenge) werden vor dem
--        INSERT konsumiert -> hoechstens eine offene Challenge je Ziel (haelt die Partial-UNIQUE
--        -Indizes konfliktfrei).
--   RUECKGABE: {ok:true, id, role, expires_at} | {ok:false, reason}
--   Invarianten-Tests: tests/db/core/test_fn_pairing_challenge.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_arm_pairing_challenge(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat  TEXT   := NULLIF(p->>'chat_id', '');
    v_tg    BIGINT;
    v_role  TEXT   := p->>'role';
    v_chal  TEXT   := COALESCE(p->>'challenge', '');
    v_pid   TEXT   := NULLIF(p->>'person_id', '');   -- WS-5a: Member-Einladungs-Ziel (NULL beim Owner-Bootstrap)
    v_id    INT;
    v_exp   TIMESTAMPTZ;
BEGIN
    IF v_role IS NULL OR v_role NOT IN ('owner','partner','child') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'role is required and must be owner|partner|child');
    END IF;
    IF v_chal !~ '^[A-Za-z0-9]{8,}$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'challenge must be >=8 alphanumeric characters (entropy floor)');
    END IF;
    IF p ? 'telegram_user_id' AND jsonb_typeof(p->'telegram_user_id') <> 'null' THEN
        BEGIN
            v_tg := (p->>'telegram_user_id')::bigint;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'telegram_user_id must be numeric (never a username)');
        END;
    END IF;

    -- owner-no-rearm: ein bereits etablierter (GEPAIRTER) Owner kann nicht ueber diesen Pfad neu
    -- armiert werden (Privilege-Escalation-Schutz). "Etabliert" = role=owner MIT telegram_user_id;
    -- das noch unverknuepfte Bootstrap-Skelett (telegram_user_id NULL) blockt bewusst NICHT, damit
    -- der Owner seinen Code gegen das vorab geseedete Skelett einloesen kann (Zwei-Stufen-Bootstrap).
    -- Cross-Table-Lesepruefung -> fn-Ebene (Projekt-Regel).
    IF v_role = 'owner' AND EXISTS (
        SELECT 1 FROM agent.core_contexts c,
                      jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
        WHERE c.name = 'family' AND pp->>'role' = 'owner'
          AND pp ? 'telegram_user_id' AND jsonb_typeof(pp->'telegram_user_id') <> 'null'
    ) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'a paired owner already exists; re-arming the owner pairing requires CLI access');
    END IF;

    -- Supersede: offene Challenges desselben Ziels still konsumieren (hoechstens eine offen). Ziel =
    -- gleicher chat_id ODER gleiche telegram_user_id ODER (owner) jede offene Owner-Challenge ODER
    -- (Member-Einladung, WS-5a) gleiche person_id -> haelt pairing_state_one_open_per_person konfliktfrei.
    UPDATE agent.pairing_state
    SET consumed_at = NOW()
    WHERE consumed_at IS NULL
      AND ( (v_chat IS NOT NULL AND chat_id = v_chat)
         OR (v_tg   IS NOT NULL AND telegram_user_id = v_tg)
         OR (v_role = 'owner'   AND role = 'owner')
         OR (v_pid  IS NOT NULL AND person_id = v_pid) );

    -- Der Supersede oben haelt die Partial-UNIQUE-Indizes im Normalfall konfliktfrei; bei ZWEI
    -- echt gleichzeitigen Arms desselben Ziels (getrennte Tx) kann der zweite INSERT dennoch gegen
    -- pairing_state_one_open_* laufen -> als freundliches {ok:false} fangen statt als Owner-Alert.
    BEGIN
        INSERT INTO agent.pairing_state (chat_id, telegram_user_id, role, challenge, person_id, expires_at)
        VALUES (v_chat, v_tg, v_role, v_chal, v_pid, NOW() + INTERVAL '10 minutes')
        RETURNING id, expires_at INTO v_id, v_exp;
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'a pairing challenge for this target is already open (concurrent arm); retry');
    END;

    RETURN jsonb_build_object('ok', true, 'id', v_id, 'role', v_role, 'expires_at', v_exp);
END;
$$;

-- Backup-Pfad-fn: EXECUTE-REVOKE fuer die Agent-Leserollen (Pairing laeuft ueber die Haupt-Credential).
REVOKE ALL ON FUNCTION agent.fn_arm_pairing_challenge(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_arm_pairing_challenge(JSONB) FROM context_ro;
    END IF;
END $$;
