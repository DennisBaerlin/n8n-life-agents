-- ============================================================
-- agent.fn_ui_texts_for (read-only, Text-Buendel EINES Empfaengers fester Texte)
--   Sprache, Intl-Locale und t-Map {key: text} fuer den Empfaenger eines festen Textes (Textkatalog Phase C:
--   Cron-Erinnerungen/-Berichte, Agent-Eingangs-Gates, Angebots-Karten). Empfaenger = die Person hinter p.chat_id
--   (agent.fn_resolve_sender), sonst der Owner; Sprache per agent.fn_person_lang (Person -> Owner -> en).
--   Keys = p.keys + jeder key-foermige String in p.doc (z. B. das Ergebnis einer fn_advisor_review mit
--   {kind:'tpl', value:<key>, params} — auch verschachtelt) + bei kind=enum der Wert-Key <enum>.<wert>
--   (gleiche Regel wie der Renderer). Deckel 500. Fallback der Texte wie core.fn_ui_texts (lang -> en -> Key).
--   NIE EIN RAISE beim Empfaenger: nicht-numerische/ueberlange/unbekannte chat_id oder ein kaputtes Dokument ->
--   Owner bzw. nur p.keys (fail-open-Gates und Crons haengen daran). Liefert NIE eine chat_id/Person.
--   Plain INVOKER (core_ro + Haupt-Credential lesen agent+core direkt; core.fn_hitl_texts baut darauf auf).
--   p: {chat_id?, keys?: [text], doc?: jsonb}
--   RUECKGABE: {lang, locale, language (Eigenname), language_label ("ko (한국어)", Prompt-Label), t:{key:text}}
--   Tests: tests/db/core/test_fn_ui_texts_for.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_ui_texts_for(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_keys   text[] := '{}';
    v_doc    jsonb;
    v_pid    text := NULL;
    v_sender jsonb;
    v_l      jsonb;
    v_name   text;
BEGIN
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
        p := '{}'::jsonb;
    END IF;

    -- Empfaenger: nur eine plausible Telegram-id wird aufgeloest, alles andere -> Owner (person NULL)
    BEGIN
        IF COALESCE(p->>'chat_id', '') ~ '^[0-9]{1,18}$' THEN
            v_sender := agent.fn_resolve_sender((p->>'chat_id')::bigint);
            IF COALESCE((v_sender->>'found')::boolean, false) THEN
                v_pid := v_sender->>'person_id';
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_pid := NULL;
    END;
    v_l := agent.fn_person_lang(v_pid);

    -- Keys: explizite Liste + alles Key-foermige im Dokument (robust: jede Form-Abweichung -> nur die Liste)
    BEGIN
        IF jsonb_typeof(p->'keys') = 'array' THEN
            v_keys := ARRAY(SELECT jsonb_array_elements_text(p->'keys'));
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_keys := '{}';
    END;
    v_doc := p->'doc';
    BEGIN
        IF jsonb_typeof(v_doc) IN ('object', 'array') THEN
            v_keys := v_keys || ARRAY(
                SELECT DISTINCT k FROM (
                    SELECT v #>> '{}' AS k
                      FROM jsonb_path_query(v_doc, 'strict $.**') v
                     WHERE jsonb_typeof(v) = 'string'
                    UNION ALL
                    SELECT (o->>'enum') || '.' || regexp_replace(lower(o->>'value'), '[^a-z0-9_]+', '_', 'g')
                      FROM jsonb_path_query(v_doc, 'strict $.**') o
                     WHERE jsonb_typeof(o) = 'object' AND o->>'kind' = 'enum'
                ) x
                WHERE k ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$' AND length(k) <= 200
                LIMIT 500);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    v_name := (SELECT l.name FROM core.ui_languages l WHERE l.code = v_l->>'lang');
    RETURN jsonb_build_object(
        'lang',     v_l->>'lang',
        'locale',   v_l->>'locale',
        'language', v_name,                                   -- Eigenname der Sprache
        -- EINE Adresse fuer das Prompt-Label der Sprach-Anweisung ("write in ko (한국어)"); ohne Namen nur der Code
        'language_label', (v_l->>'lang') || COALESCE(' (' || v_name || ')', ''),
        't',        core.fn_ui_texts(v_l->>'lang', v_keys));
END;
$$;

-- ============================================================
-- core.fn_ui_texts_for (publiziertes SECURITY-DEFINER-Fenster auf das agent-Primitiv oben)
--   Paket-Crons (finance_rw/_ro, estate_rw) und die Agent-Eingangs-Gates (<pkg>_ro) brauchen die Empfaenger-Texte,
--   erreichen aber weder Schema agent noch core.ui_texts (D10). Muster core.fn_person_chat_id: duenner Wrapper,
--   gehaertet (search_path gepinnt, pg_temp zuletzt; kein dynamisches SQL), PUBLIC entzogen; EXECUTE an jede
--   Paket-Rolle generisch in core.fn_provision_package_roles. Liefert nur Sprache/Locale/Texte, nie Personen-Daten.
--   RUECKGABE: wie agent.fn_ui_texts_for
--   Tests: tests/db/core/test_fn_ui_texts_for.sql; Paket-Rollen-Perspektive tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_texts_for(p jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT agent.fn_ui_texts_for(p);
$$;

REVOKE ALL ON FUNCTION core.fn_ui_texts_for(jsonb) FROM public;
