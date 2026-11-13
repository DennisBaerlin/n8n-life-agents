-- ============================================================
-- fn_consume_pairing_challenge (Multi-User-Pairing — Einmal-Code einloesen)
--   Die atomare Durchsetzung der Pairing-Invarianten:
--   die Match-Bedingungen stehen zusaetzlich im aeusseren WHERE des UPDATE (READ COMMITTED:
--   ein uncorrelated Subselect wird beim EvalPlanQual-Recheck nicht neu evaluiert -> sonst
--   koennten zwei parallele Commits beide einloesen), FOR UPDATE SKIP LOCKED verhindert das
--   Warten auf den jeweils anderen.
--   Eine in agent.access_blocks gesperrte uid wird vor dem Consume abgewiesen ({ok:false,blocked}).
--   Eingabe p: { chat_id, challenge, telegram_user_id, person_id }
--      telegram_user_id = live from.id des einloesenden Senders (Identitaet wird an den lebenden
--        Sender gebunden, nicht an einen arm-Zeit-Wert — OpenClaw-CVE: numerische Identitaet); Pflicht.
--      person_id        = bestehende family-Person, an die telegram_user_id+role gemergt werden.
--   Ablauf:
--     1) Exakt-Match-Consume (race-fest): Code exakt (getrimmt), Chat passt (chat_id IS NULL =
--        Owner-Bootstrap matcht jeden Chat), armierte Identitaet passt (telegram_user_id IS NULL
--        oder == Sender), nicht konsumiert, nicht abgelaufen, fail_count < 3.
--        -> bei Treffer Merge telegram_user_id+role in die bestehende Person via den Merge-Kern
--           fn_merge_member_identity (-> fn_set_context_facts; der birth_date-Validator bleibt
--           Backstop — die Person traegt ihren Stammsatz aus dem Onboarding bereits).
--           Schlaegt der Merge fehl (Person fehlt / unvollstaendig), RAISE -> die ganze
--           Transaktion (inkl. consumed_at) rollt zurueck, die Challenge bleibt offen.
--     2) kein Exakt-Match, aber offene Challenge fuer diesen Chat -> Fehlversuch zaehlen
--        (fail_count++); beim 3. -> consumed_at = NOW() (Challenge invalidiert, OWASP-Lockout).
--     3) sonst {ok:false}.
--   Rueckgabe: {ok:true, role, telegram_user_id, person_id}
--            | {ok:false, reason, fail_count, locked}   (Fehlversuch an offener Challenge)
--            | {ok:false, blocked:true}                  (uid gesperrt)
--            | {ok:false, reason}                        (telegram_user_id fehlt)
--            | {ok:false}                                (kein Match / nichts offen)
--   Invarianten-Tests: tests/db/core/test_fn_pairing_challenge.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_consume_pairing_challenge(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat   TEXT   := p->>'chat_id';
    v_tg     BIGINT;
    v_role   TEXT;
    v_pid    TEXT   := p->>'person_id';
    v_merge  JSONB;
    v_fail   INT;
BEGIN
    IF COALESCE(p->>'telegram_user_id', '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'telegram_user_id (live sender id) is required');
    END IF;
    v_tg := (p->>'telegram_user_id')::bigint;

    -- Eine gesperrte uid kann sich auch mit gueltigem Owner-Bootstrap-Code nicht verbinden.
    IF agent.fn_is_blocked(v_tg) THEN
        RETURN jsonb_build_object('ok', false, 'blocked', true);
    END IF;

    -- (1) Exakt-Match-Consume (race-fest, Bedingungen auch im aeusseren WHERE).
    UPDATE agent.pairing_state
    SET consumed_at = NOW()
    WHERE id = (SELECT id FROM agent.pairing_state
                WHERE challenge = trim(COALESCE(p->>'challenge', ''))
                  AND (chat_id IS NULL OR chat_id = v_chat)
                  AND (telegram_user_id IS NULL OR telegram_user_id = v_tg)
                  AND consumed_at IS NULL AND expires_at > NOW() AND fail_count < 3
                ORDER BY id DESC LIMIT 1
                FOR UPDATE SKIP LOCKED)
      AND consumed_at IS NULL AND expires_at > NOW() AND fail_count < 3
    RETURNING role INTO v_role;

    IF v_role IS NOT NULL THEN
        IF COALESCE(v_pid, '') = '' THEN
            RAISE EXCEPTION 'pairing consume: person_id is required to attach the identity';
        END IF;
        -- Zwei-Stufen-Bootstrap: telegram_user_id + role in die bestehende Person mergen ueber den
        -- geteilten Kern (as_of-Bewahrung + Doppel-Bind-Backstop dort, derselbe wie fn_confirm_pairing).
        -- Beim Owner-Bootstrap ist die Zielperson das unverknuepfte Skelett (telegram_user_id NULL) ->
        -- der Kern merged sofort. Schlaegt der Merge fehl (Person fehlt / unerwartet schon gepairt),
        -- RAISE -> Rollback der Consume (consumed_at), die Challenge bleibt offen.
        v_merge := agent.fn_merge_member_identity(v_pid, v_tg, v_role);
        IF (v_merge->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'pairing consume: family merge failed for person "%": %', v_pid, v_merge->>'reason';
        END IF;
        RETURN jsonb_build_object('ok', true, 'role', v_role, 'telegram_user_id', v_tg, 'person_id', v_pid);
    END IF;

    -- (2) Fehlversuch an einer offenen Challenge dieses Chats zaehlen; 3. -> invalidieren.
    --     chat_id IS NULL (Owner-Bootstrap-Challenge matcht jeden Chat) muss hier ebenfalls greifen —
    --     dieselbe Bindung wie der Exakt-Match oben (Schritt 1), sonst zaehlt ein Owner-Code-Bruteforce
    --     nie einen Fehlversuch und der OWASP-Lockout liefe leer.
    UPDATE agent.pairing_state
    SET fail_count  = fail_count + 1,
        consumed_at = CASE WHEN fail_count + 1 >= 3 THEN NOW() ELSE consumed_at END
    WHERE id = (SELECT id FROM agent.pairing_state
                WHERE (chat_id IS NULL OR chat_id = v_chat)
                  AND consumed_at IS NULL AND expires_at > NOW()
                ORDER BY id DESC LIMIT 1
                FOR UPDATE SKIP LOCKED)
      AND consumed_at IS NULL AND expires_at > NOW()
    RETURNING fail_count INTO v_fail;

    IF v_fail IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'incorrect pairing code',
                                  'fail_count', v_fail, 'locked', v_fail >= 3);
    END IF;

    RETURN jsonb_build_object('ok', false);
END;
$$;

-- EXECUTE-REVOKE fuer die Agent-Leserollen (Pairing laeuft ueber die Haupt-Credential).
REVOKE ALL ON FUNCTION agent.fn_consume_pairing_challenge(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_consume_pairing_challenge(JSONB) FROM context_ro;
    END IF;
END $$;
