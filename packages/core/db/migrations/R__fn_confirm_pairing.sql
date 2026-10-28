-- ============================================================
-- fn_confirm_pairing (WS-5a — Owner bestaetigt die gestagete Einladung -> BINDUNG committen)
--   Schritt 3 (Approve): der Owner tippt ✅ am callback_query. Die Owner-Auth (from.id == Owner) liegt
--   DETERMINISTISCH im Orchestrator-Handler VOR diesem Aufruf (LLM entscheidet keine Auth); diese fn ist
--   die atomare Durchsetzung. Bindet die beim Claim gestagete Member-Identitaet (claimed_uid) an die
--   Einladungs-Person (person_id) ueber den geteilten Merge-Kern (fn_merge_member_identity).
--   IDEMPOTENT (Opus-Reviewer): zweites ✅ (Telegram-Retry / Doppel-Tap) findet consumed_at gesetzt ->
--   {ok:false, resolved:true}, KEIN zweiter Merge, kein Owner-Alert. Schon-gepairt/Merge-Fehler reicht der
--   Kern als freundliches {ok:false} bzw. RAISE (Rollback) durch.
--   p: { id }   (pairing_state.id aus dem callback_data confirm:<id>)
--   RUECKGABE: {ok:true, person_id, role, full_name, telegram_user_id, member_chat_id, language_hint, has_language, members_have_areas}
--            (language_hint = Telegram-App-Sprache vom claim, nur Vorschlag; has_language = Person hat schon eine
--             eigene Sprache -> der Orchestrator schickt den Sprach-Picker nur, wenn false; members_have_areas = der Haushalt
--             ist fertig eingerichtet UND ein aktives persoenliches (per_user) Paket hat Onboarding-Abschnitte -> die
--             Bestaetigung traegt den Knopf 'Meine Bereiche' (2026-10-28: 'Es kann losgehen' kommt nur EINMAL, beim ersten
--             Haushalts-Abschluss; ein spaeter verbundenes Mitglied erfuhr sonst nie von seinen Bereichen))
--            | {ok:false, resolved:true}        (bereits bestaetigt/abgelehnt -> idempotent)
--            | {ok:false, reason, member_chat_id?}  (noch nicht eingeloest / already paired)
--   Invarianten-Tests: tests/db/core/test_fn_pairing_challenge.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_confirm_pairing(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id    INT := NULLIF(p->>'id', '')::int;
    v_pid   TEXT;
    v_role  TEXT;
    v_uid   BIGINT;
    v_chat  TEXT;
    v_done  TIMESTAMPTZ;
    v_merge JSONB;
    v_name  TEXT;
    v_hint  TEXT;
    v_haslang BOOLEAN;
BEGIN
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'pairing id is required');
    END IF;

    SELECT person_id, role, claimed_uid, claimed_chat_id, consumed_at, language_hint
    INTO v_pid, v_role, v_uid, v_chat, v_done, v_hint
    FROM agent.pairing_state WHERE id = v_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'pairing request not found');
    END IF;
    IF v_done IS NOT NULL THEN
        -- Bereits bestaetigt/abgelehnt -> idempotenter no-op (Doppel-Tap / Telegram-Retry).
        RETURN jsonb_build_object('ok', false, 'resolved', true);
    END IF;
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'pairing was not claimed by a member yet');
    END IF;

    -- Bindung committen (as_of-Bewahrung + Doppel-Bind-Backstop im Kern). RAISE im Kern -> Rollback,
    -- Stage bleibt offen. {ok:false} (z. B. zwischenzeitlich schon gepairt) -> kein consume, freundlich.
    v_merge := agent.fn_merge_member_identity(v_pid, v_uid, v_role);
    IF (v_merge->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_merge || jsonb_build_object('member_chat_id', v_chat);
    END IF;

    UPDATE agent.pairing_state SET consumed_at = NOW() WHERE id = v_id;

    SELECT NULLIF(trim(concat_ws(' ', pp->>'first_name', pp->>'last_name')), ''),
           NULLIF(btrim(pp->>'language'), '') IS NOT NULL
      INTO v_name, v_haslang
    FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
    WHERE c.name = 'family' AND pp->>'person_id' = v_pid
    LIMIT 1;

    RETURN jsonb_build_object('ok', true, 'person_id', v_pid, 'role', v_role, 'full_name', v_name,
                              'telegram_user_id', v_uid, 'member_chat_id', v_chat,
                              'language_hint', v_hint, 'has_language', COALESCE(v_haslang, false),
                              'members_have_areas',
                                  NOT EXISTS (SELECT 1 FROM agent.guide_onboarding_state WHERE status = 'unknown')
                                  AND core.fn_has_personal_onboarding_areas());
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_confirm_pairing(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_confirm_pairing(JSONB) FROM context_ro;
    END IF;
END $$;
