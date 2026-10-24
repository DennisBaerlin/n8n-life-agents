-- ============================================================
-- fn_resolve_sender (read-only, Identity-Link)
--   Telegram-User-ID -> Haushaltsmitglied (family-Facts-Sidecar). Konsument: read-only
--   Orchestrator-Step vor dem Router — injiziert sender_member ("Current user: Lena") in den
--   Turn (Pre-Fill, Personen-Aufloesung "mein Konto", Antwortsprache).
--   Eindeutigkeit der telegram_user_id ueber Personen erzwingt der Validierungs-Trigger
--   (agent.core_init.sql) — hier genuegt LIMIT 1.
--   RUECKGABE: {found:true, person_id, full_name, role, language, chat_id} | {found:false}
--   WP-5c: chat_id = die KANONISCHE telegram_user_id der aufgeloesten Person (= der Match-Schluessel). Der
--     HITL-Member-Send adressiert damit die verifizierte Identitaet, nicht die roh eingehende chat_id.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_resolve_sender(p_telegram_user_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'found',     true,
        'person_id', pp->>'person_id',
        'full_name', (pp->>'first_name') || ' ' || (pp->>'last_name'),
        'role',      pp->>'role',
        'language',  pp->>'language',
        'chat_id',   (pp->>'telegram_user_id')::bigint)
    INTO v_result
    FROM agent.core_contexts c,
         jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family'
      AND jsonb_typeof(pp->'telegram_user_id') <> 'null'
      AND (pp->>'telegram_user_id')::bigint = p_telegram_user_id
    LIMIT 1;

    RETURN COALESCE(v_result, jsonb_build_object('found', false));
END;
$$;
