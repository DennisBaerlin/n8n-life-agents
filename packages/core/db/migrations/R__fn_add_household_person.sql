-- ============================================================
-- fn_add_household_person (Person anlegen)
--   Owner-CLI (`lifeagents household add`): legt eine neue Haushalts-Person in der Autoring-Quelle `family` an.
--   Den Slug `person_id` vergibt agent.fn_person_slug (Vorname, Umlaute transliteriert, eindeutig); den Append
--   delegiert die fn an fn_set_context_facts (Validierung des vollen Skeletts, Projektion und as_of-Stempel laufen dort).
--
--   owner_only-Backstop: fn_set_context_facts lehnt fuer family einen positiv aufgeloesten Nicht-Owner-chat_id ab.
--   Der Payload hier traegt bewusst keinen chat_id-Key: die CLI ist OS-/SSH-autorisiert (postgres-Superuser), nicht
--   chat-autorisiert, der Backstop greift nie (fn_sender_is_member(NULL) = false). Nie eine Caller-chat_id
--   durchreichen, sonst loest eine Member-chat_id den Backstop aus.
--   Eingabe p: { first_name, last_name, birth_date (YYYY-MM-DD), role (owner|partner|child) } alle Pflicht;
--      language? = Sprache fester Texte (Code oder freie Angabe, normiert via agent.fn_normalize_language;
--      nicht unterstuetzt -> {ok:false}; fehlt -> Laufzeit-Fallback Owner-Sprache).
--   Rueckgabe: {ok:true, person_id, full_name, role} | {ok:false, reason}; reason = "first_name and last_name are
--      required", "birth_date is required (YYYY-MM-DD)", "role must be owner|partner|child", "language ... is not
--      supported" oder der durchgereichte reason aus fn_set_context_facts.
--   Seiteneffekt: Append der Person in den Context `family` (via fn_set_context_facts).
--   Tests: tests/db/core/test_fn_household_person.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_add_household_person(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_first TEXT := NULLIF(trim(p->>'first_name'), '');
    v_last  TEXT := NULLIF(trim(p->>'last_name'), '');
    v_bdate TEXT := NULLIF(trim(p->>'birth_date'), '');
    v_role  TEXT := NULLIF(trim(p->>'role'), '');
    v_lraw  TEXT := NULLIF(trim(p->>'language'), '');
    v_lang  TEXT := agent.fn_normalize_language(p->>'language');
    v_slug  TEXT;
    v_set   JSONB;
BEGIN
    -- Freundliche Vorab-Guards (der Validator faengt sie auch, aber mit praezisem Grund + ohne RAISE).
    IF v_first IS NULL OR v_last IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'first_name and last_name are required');
    END IF;
    IF v_bdate IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'birth_date is required (YYYY-MM-DD)');
    END IF;
    IF COALESCE(v_role, '') NOT IN ('owner', 'partner', 'child') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'role must be owner|partner|child');
    END IF;
    IF v_lraw IS NOT NULL AND v_lang IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('language "%s" is not supported (use one of: %s)',
            v_lraw, (SELECT string_agg(l.code, '|' ORDER BY l.ord) FROM core.ui_languages l)));
    END IF;

    -- Slug aus dem Vornamen, eindeutig (die eine Adresse: agent.fn_person_slug).
    v_slug := agent.fn_person_slug(v_first);

    -- Delegieren — kein chat_id im Payload (s. Header: owner_only-Backstop bewusst umgangen).
    v_set := agent.fn_set_context_facts(jsonb_build_object(
        'context_name', 'family',
        'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
            'person_id',  v_slug,
            'first_name', v_first,
            'last_name',  v_last,
            'birth_date', v_bdate,
            'role',       v_role,
            'language',   v_lang))))));
    IF (v_set->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_set->>'reason');
    END IF;

    RETURN jsonb_build_object('ok', true, 'person_id', v_slug,
                              'full_name', v_first || ' ' || v_last, 'role', v_role);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_add_household_person(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_add_household_person(JSONB) FROM context_ro;
    END IF;
END $$;
