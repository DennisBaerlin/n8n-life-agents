-- ============================================================
-- fn_merge_member_identity (ATOMIC WRITE)
--   Die eine Stelle, die telegram_user_id + role in eine bestehende family-Person merged. Gerufen von
--   zwei Pfaden: fn_consume_pairing_challenge (Owner-Bootstrap, sofort-bindend) und fn_confirm_pairing
--   (Member-Einladung, owner-bestaetigt).
--   Eingabe: p_person_id, p_uid (telegram_user_id), p_role (alle Pflicht; leere person_id oder NULL-uid -> RAISE).
--
--   Doppel-Bind-/Replay-Backstop: der family-Validator (trg_validate_household_facts)
--   faengt nur uid-Kollisionen innerhalb einer Write-Payload, nicht "diese Person ist schon gepairt".
--   fn_set_context_facts merged zudem bedingungslos (kein WHERE telegram_user_id IS NULL). Darum liest
--   dieser Kern die aktuelle telegram_user_id der Zielperson selbst vorab:
--     - bereits == p_uid  -> idempotenter no-op {ok:true, already:true} (Replay / Owner-Doppel-Confirm)
--     - bereits != p_uid  -> {ok:false, already paired} (Doppel-Bind-Schutz)
--     - NULL              -> mergen (as_of der Person bewahren -> kein Staleness-Sprung, Pairing ist
--                            keine Fakten-Aktualisierung).
--   Person fehlt / family-Merge schlaegt fehl -> RAISE (person_id ist system-aufgeloest) -> der Aufrufer
--   rollt seine Transaktion (consumed_at) zurueck, die Challenge bleibt offen.
--   RUECKGABE: {ok:true, role, telegram_user_id, person_id [, already]} | {ok:false, reason}
--   (reason: person is already paired to a different identity).
--   Invarianten-Tests: tests/db/core/test_fn_merge_member_identity.sql + test_fn_pairing_challenge.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_merge_member_identity(p_person_id text, p_uid bigint, p_role text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_person JSONB;
    v_as_of  TEXT;
    v_set    JSONB;
BEGIN
    IF COALESCE(p_person_id, '') = '' THEN
        RAISE EXCEPTION 'merge member identity: person_id is required';
    END IF;
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'merge member identity: telegram_user_id is required';
    END IF;

    SELECT pp INTO v_person
    FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
    WHERE c.name = 'family' AND pp->>'person_id' = p_person_id
    LIMIT 1;   -- person_id-Eindeutigkeit ist Validator-erzwungen -> deterministisch

    IF v_person IS NULL THEN
        -- Person fehlt: echte Ausnahme (system-aufgeloeste person_id) -> Rollback beim Aufrufer.
        RAISE EXCEPTION 'merge member identity: person "%" not found in family facts', p_person_id;
    END IF;

    IF v_person ? 'telegram_user_id' AND jsonb_typeof(v_person->'telegram_user_id') <> 'null' THEN
        IF (v_person->>'telegram_user_id')::bigint = p_uid THEN
            -- Replay / Owner-Doppel-Confirm: Identitaet schon gebunden -> idempotenter no-op.
            RETURN jsonb_build_object('ok', true, 'already', true, 'role', p_role,
                                      'telegram_user_id', p_uid, 'person_id', p_person_id);
        END IF;
        -- Zielperson traegt bereits eine andere Identitaet -> Doppel-Bind-Backstop.
        RETURN jsonb_build_object('ok', false,
            'reason', format('person "%s" is already paired to a different identity', p_person_id));
    END IF;

    v_as_of := v_person->>'as_of';   -- Skelett-as_of bewahren (kein Staleness-Stempel auf heute)

    -- Bewusst ohne chat_id (Pairing ist nicht chat-autorisiert; der owner_only-Backstop greift nicht).
    v_set := agent.fn_set_context_facts(jsonb_build_object(
        'context_name', 'family',
        'facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id', p_person_id, 'telegram_user_id', p_uid, 'role', p_role)
            || CASE WHEN v_as_of IS NOT NULL
                    THEN jsonb_build_object('as_of', v_as_of) ELSE '{}'::jsonb END))));
    IF (v_set->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'merge member identity: family merge failed for person "%": %', p_person_id, v_set->>'reason';
    END IF;

    RETURN jsonb_build_object('ok', true, 'role', p_role,
                              'telegram_user_id', p_uid, 'person_id', p_person_id);
END;
$$;

-- Laeuft ueber die Haupt-Credential (wie die anderen Pairing-fns) -> EXECUTE-REVOKE fuer die Leserollen.
REVOKE ALL ON FUNCTION agent.fn_merge_member_identity(text, bigint, text) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_merge_member_identity(text, bigint, text) FROM context_ro;
    END IF;
END $$;
