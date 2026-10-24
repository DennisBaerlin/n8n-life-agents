-- ============================================================
-- fn_unlink_member_identity (WS-5d — Telegram-ID von einer Person trennen, „neues Konto")
--   Owner-CLI (`lifeagents household unlink <person_id>`): entfernt den telegram_user_id-Key CHIRURGISCH
--   (jsonb `-`) aus dem Person-Objekt in `family`. Danach findet fn_resolve_sender die alte uid nicht
--   mehr (Bedingung jsonb_typeof <> 'null' schlaegt nicht an) -> die Person ist wieder „unbekannt" und
--   per neuer Owner-Einladung (WS-5a) re-pairbar (der Merge-Kern fn_merge_member_identity bindet wieder,
--   weil die Person keine uid mehr traegt).
--
--   Dediziert statt fn_set_context_facts-„null-Merge": fn_set_context_facts ist merge/append-only
--   (kann den Key gar nicht entfernen, nur auf JSON-null setzen) und traegt den owner_only-chat_id-
--   Backstop -> explizite Key-Entfernung ist sauberer (arch-challenge D4, Auth0/RFC-7009-Muster).
--   Guards: Person fehlt -> {ok:false}; keine uid gesetzt -> {ok:false}. Der OWNER darf entknuepft werden
--     (Owner-Entscheid): er hat Root/CLI-Zugang und kann sich nie echt aussperren -> nach dem Unlink armt
--     `lifeagents household pair-owner` einen frischen Owner-Code (fn_arm_pairing_challenge, das einen GEPAIRTEN
--     Owner ohnehin ablehnt) -> /start <code> vom neuen Konto re-bindet. Nur das LOESCHEN des Owners bleibt
--     blockiert (fn_remove_household_person) — das ist die einzige sakrale Invariante (Owner-Person muss existieren).
--   p: { person_id }
--   RUECKGABE: {ok:true, person_id, freed_telegram_user_id} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_household_person.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_unlink_member_identity(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pid     TEXT := NULLIF(trim(p->>'person_id'), '');
    v_persons JSONB;
    v_person  JSONB;
    v_idx     INT;
    v_i       INT;
    v_uid     BIGINT;
BEGIN
    IF v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'person_id is required');
    END IF;

    SELECT metadata->'facts'->'persons' INTO v_persons
    FROM agent.core_contexts WHERE name = 'family' FOR UPDATE;

    v_idx := NULL;
    FOR v_i IN 0 .. COALESCE(jsonb_array_length(v_persons), 0) - 1 LOOP
        IF v_persons->v_i->>'person_id' = v_pid THEN
            v_idx := v_i; v_person := v_persons->v_i; EXIT;
        END IF;
    END LOOP;
    IF v_idx IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('person "%s" not found in household', v_pid));
    END IF;
    -- Owner-Unlink ist ERLAUBT (Owner hat Root -> re-linkt via `lifeagents household pair-owner` + /start);
    -- nur das LOESCHEN des Owners bleibt blockiert (fn_remove_household_person).
    IF NOT (v_person ? 'telegram_user_id' AND jsonb_typeof(v_person->'telegram_user_id') <> 'null') THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('person "%s" is not linked to a Telegram identity', v_pid));
    END IF;
    v_uid := (v_person->>'telegram_user_id')::bigint;

    -- Key chirurgisch entfernen + die Person an ihrem Index ersetzen -> family-UPDATE (Re-Projektion,
    -- full_name/role unveraendert -> kein GC; Validator akzeptiert das Entfernen einer uid).
    v_persons := jsonb_set(v_persons, ARRAY[v_idx::text], (v_person - 'telegram_user_id'));
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons}', v_persons)
    WHERE name = 'family';

    RETURN jsonb_build_object('ok', true, 'person_id', v_pid, 'freed_telegram_user_id', v_uid);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_unlink_member_identity(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_unlink_member_identity(JSONB) FROM context_ro;
    END IF;
END $$;
