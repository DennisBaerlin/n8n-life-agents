-- ============================================================
-- core.fn_hitl_texts (read-only, Text-Buendel des HITL-Gates agent.tool_human_approval)
--   Liefert je MOEGLICHEM Empfaenger die Sprache, das Intl-Locale und alle Texte, die der Gate-Renderer
--   ('Compose messages', Get-HitlComposeJs) braucht: die Gate-Chrome-Keys (Hinweis, Knoepfe, Mitglied-Texte,
--   "Teil n/N" langer Karten, Format-Woerter) + jeden key-foermigen String des strukturierten Summary (New-HitlSummary: title, labels,
--   note-/key-/tpl-Werte, Parameter) und bei kind=enum den Wert-Key <enum>.<wert> (Wert lower + Nicht-[a-z0-9_]
--   -> '_', dieselbe Regel im Renderer).
--   Ein Lookup-Pfad: beide Buendel kommen aus agent.fn_ui_texts_for (dieselbe Key-Sammlung + Sprach-Kette wie die
--   Cron-/Gate-Texte), ohne den DEFINER-Wrapper -> das Gate braucht unter core_ro keinen weiteren Grant.
--     owner  = Sprache des Owners (agent.fn_person_lang, Kette Person -> Owner -> en)
--     member = nur wenn chat_id numerisch ist UND zu einem Nicht-Owner aufloest (agent.fn_resolve_sender —
--              dieselbe Quelle wie der Gate-Zweig 'Is member?'), sonst null; traegt den Namen fuer die
--              Owner-Texte "Mitglied X beantragt" / "X hat bestaetigt".
--   SICHERHEIT: liefert NIE eine chat_id — Texte entscheiden nie ueber Empfaenger/approverIds (die bleiben im
--   Gate an Resolve sender/$OWNER_CHAT_ID gebunden). Wirft nie bei kaputtem/String-Summary (dann nur die
--   Chrome-Keys); ein DB-Fehler stoppt das Gate fail-closed (kein onError am Knoten).
--   languages = Code -> Eigenname (Zeilen kind=language).
--   p: {summary, chat_id}
--   RUECKGABE: {owner:{lang, locale, t:{key:text}}, member:{lang, locale, name, t}|null, languages:{code:name}}
--   Tests: tests/db/core/test_fn_hitl_texts.sql; core_ro-Perspektive tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_hitl_texts(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_chrome  text[] := ARRAY[
        'core.hitl.hint', 'core.hitl.approve', 'core.hitl.cancel', 'core.hitl.unauthorized',
        'core.hitl.member_requests', 'core.hitl.member_confirmed', 'core.hitl.part',
        'core.fmt.empty', 'core.fmt.default_suffix', 'core.fmt.yes', 'core.fmt.no', 'core.fmt.removed'];
    -- Die Summary-Keys sammelt agent.fn_ui_texts_for aus dem Dokument (robust: jede Form-Abweichung -> nur
    -- Chrome-Keys). Generisch: JEDER key-foermige String im Summary (title, labels, note-/key-/tpl-Werte, auch
    -- verschachtelte Parameter) + die Enum-Wert-Keys; Deckel 500. Ein Nutzer-Freitext, der zufaellig key-foermig
    -- ist, kostet nur einen Fallback-Eintrag (der Renderer uebersetzt nur Felder, die er als Key kennt).
    v_req     jsonb := jsonb_build_object('keys', to_jsonb(v_chrome), 'doc', p->'summary');
    v_owner   jsonb;
    v_member  jsonb := NULL;
    v_sender  jsonb;
BEGIN
    v_owner := agent.fn_ui_texts_for(v_req);   -- ohne chat_id = Owner

    IF COALESCE(p->>'chat_id', '') ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender((p->>'chat_id')::bigint);
        IF COALESCE((v_sender->>'found')::boolean, false) AND v_sender->>'role' IS DISTINCT FROM 'owner' THEN
            -- Keys = die schon gesammelten des Owner-Buendels (fn_ui_texts liefert jeden angefragten Key, notfalls
            -- als Key selbst) -> das Summary wird nur EINMAL gescannt.
            v_member := agent.fn_ui_texts_for(jsonb_build_object(
                            'chat_id', p->>'chat_id',
                            'keys', COALESCE((SELECT jsonb_agg(k) FROM jsonb_object_keys(v_owner->'t') k), to_jsonb(v_chrome))))
                        || jsonb_build_object('name', v_sender->>'full_name');
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'owner',     v_owner,
        'member',    v_member,
        'languages', COALESCE((SELECT jsonb_object_agg(l.code, l.name) FROM core.ui_languages l), '{}'::jsonb));
END;
$$;
