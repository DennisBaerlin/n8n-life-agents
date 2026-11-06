-- ============================================================
-- core.fn_app_refusal (READ) — die eine Ablehnungs-Antwort der Mini-App an die Seite (docs/package-contract.md §3.12)
--   Feste Zuordnung Code -> Text-Key (drei Saetze genuegen der Seite): expired -> „neu oeffnen“; alles, was auf
--   fehlende Berechtigung deutet (malformed, bad_signature, unknown, not_allowed, forbidden) -> „kein Zugriff“;
--   alles andere (disabled, unavailable, unknown_screen, error, no_secret) -> „gerade nicht verfuegbar“.
--   Sprache = die Person hinter p_chat (agent.fn_ui_texts_for: Person -> Owner -> en); nennt nie eine Person.
--   p_code: Ablehnungs-Code; p_chat: Telegram-id als Text oder NULL
--   RUECKGABE: {ok:false, code, text:{kind:'tpl',…}, ui:{lang, locale, t}}
--   Tests: tests/db/core/test_fn_app_screen.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_refusal(p_code text, p_chat text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_text jsonb;
BEGIN
    v_text := CASE
        WHEN p_code = 'expired' THEN core.fn_ui_tpl('core.app.error.expired')
        WHEN p_code IN ('malformed', 'bad_signature', 'unknown', 'not_allowed', 'forbidden')
            THEN core.fn_ui_tpl('core.app.error.denied')
        ELSE core.fn_ui_tpl('core.app.error.unavailable')
    END;
    RETURN jsonb_build_object(
        'ok', false,
        'code', COALESCE(p_code, 'error'),
        'text', v_text,
        'ui', agent.fn_ui_texts_for(jsonb_build_object(
                  'chat_id', p_chat,
                  'keys', to_jsonb(ARRAY['core.app.title', 'core.app.reload', 'core.app.gap', 'core.fmt.empty']),
                  'doc', v_text)));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_app_refusal(text, text) FROM public;
