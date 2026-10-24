-- ============================================================
-- agent.fn_set_person_persona (Callback-Handler des Persona-Pickers, Prefix persona:<person_id>:<code>)
--   Registriert in core.callback_handlers (Core-Manifest callback_handlers, member_permeable=true); der Dispatcher
--   core.fn_dispatch_callback laesst Owner und aufgeloeste Mitglieder durch, die FEINE Autorisierung liegt hier:
--     Owner -> jede Person; Mitglied -> nur sich selbst; unaufgeloester Absender -> abgelehnt.
--   Analog agent.fn_set_person_language (gleiche Zero-Trust-Regeln, gleicher Schreibweg):
--   ZERO-TRUST: re-resolvt den Absender selbst aus p->>'chat_id' (RAISE-freier Cast), vertraut keinem Caller-Flag.
--   Der Tipp IST die Bestaetigung, kein HITL-Gate davor. Write ueber agent.fn_set_context_facts OHNE chat_id
--   (vertrauenswuerdiger Aufruf; die family-owner_only-Pruefung dort uebernimmt diese Autorisierung), genau
--   {person_id, persona} — 'neutral' loescht dort den Key (neutral wird nie gespeichert).
--   Toast in der Sprache des TIPPENDEN (die Persona aendert die Sprache nicht), Texte core.persona.*, Persona-Name
--   aus core.persona.name.<code>.
--   p: das Callback-Payload {data, chat_id, ...}
--   RUECKGABE: {ok:true, person_id, persona, toast} | {ok:false, reason, toast}  (nie RAISE -> kein Owner-Alert)
--   Tests: tests/db/core/test_fn_set_person_persona.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_person_persona(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog   -- Paritaet der Callback-Handler (alle Refs schema-qualifiziert, CVE-2018-1058)
AS $$
DECLARE
    v_data    text := COALESCE(p->>'data', '');
    v_pid     text := NULLIF(split_part(v_data, ':', 2), '');
    v_code    text := NULLIF(split_part(v_data, ':', 3), '');
    v_chat    bigint;
    v_sender  jsonb;
    v_target  jsonb;
    v_lang    text;
    v_set     jsonb;
BEGIN
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := agent.fn_resolve_sender(v_chat);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unresolved_sender',
            'toast', core.fn_ui_text('core.persona.not_allowed', 'en'));
    END IF;
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';   -- Sprache des Tippenden

    SELECT pp INTO v_target
      FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
     WHERE c.name = 'family' AND pp->>'person_id' = v_pid
     LIMIT 1;
    IF v_pid IS NULL OR v_target IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_person',
            'toast', core.fn_ui_text('core.persona.failed', v_lang));
    END IF;
    IF v_code IS NULL OR NOT EXISTS (SELECT 1 FROM core.ui_personas x WHERE x.code = v_code) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unsupported_persona',
            'toast', core.fn_ui_text('core.persona.failed', v_lang));
    END IF;
    IF v_sender->>'role' IS DISTINCT FROM 'owner' AND v_sender->>'person_id' IS DISTINCT FROM v_pid THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed',
            'toast', core.fn_ui_text('core.persona.not_allowed', v_lang));
    END IF;

    v_set := agent.fn_set_context_facts(jsonb_build_object(
        'context_name', 'family',
        'facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id', v_pid, 'persona', v_code)))));
    IF (v_set->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_set->>'reason',
            'toast', core.fn_ui_text('core.persona.failed', v_lang));
    END IF;

    RETURN jsonb_build_object('ok', true, 'person_id', v_pid, 'persona', v_code,
        'toast', core.fn_ui_text('core.persona.saved', v_lang,
                                 jsonb_build_object('name', v_target->>'first_name',
                                                    -- Enum-Prefix + Code (locale_lint 7b sichert je Code den Key)
                                                    'persona', core.fn_ui_text('core.persona.name' || '.' || v_code, v_lang))));
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_set_person_persona(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_set_person_persona(JSONB) FROM context_ro;
    END IF;
END $$;
