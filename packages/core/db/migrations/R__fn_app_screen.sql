-- ============================================================
-- core.fn_app_screen (READ, Dispatcher) — der eine Eingang der Mini-App „Übersicht“ (docs/package-contract.md §3.12)
--   Die Seite schickt per POST {init_data, screen?, params?} (roh als Text, der Workflow reicht ihn ungeprueft durch).
--   Kette, jede Stufe lehnt ueber core.fn_app_refusal ab (nie ein RAISE, sonst ein Owner-Alert je Muell-Anfrage):
--     Frei-SQL-Sitzung -> forbidden; Body kein JSON-Objekt -> malformed; initData (core.fn_app_verify_init_data) ->
--     malformed/bad_signature/expired/no_secret; Person selbst aufloesen (agent.fn_resolve_sender, Zero-Trust: eine
--     person_id im Body zaehlt nie) -> unknown; core.config app.enabled (fail-closed: fehlt die Zeile = aus) ->
--     disabled; app.audience ('household' = alle aufgeloesten Personen, sonst nur der Owner) -> not_allowed.
--   Ohne screen: Navigation = die Bildschirme aktiver Pakete (core.fn_package_active + to_regprocedure), deren
--     Handler fuer diese Person nicht leer ist (params.probe=true -> {ok, empty}); Titel-Key <pkg>.app.screen.<screen>.
--   Mit screen: Registry -> unknown_screen, Paket inaktiv/Handler fehlt -> unavailable, Handler wirft -> error,
--     Handler lehnt ab -> sein code. Der Handler bekommt {person_id, params} und loest die Rolle SELBST auf.
--   ui = agent.fn_ui_texts_for fuer die Person mit allen Keys der Antwort + den Shell-Keys (core.app.*, core.fmt.*).
--   INVOKER unter der Host-Credential (Muster core.fn_dispatch_callback); handler_fn ist installer-geschrieben und per
--   CHECK schema-qualifiziert, nie Caller-Input.
--   p: Request-Body als Text
--   RUECKGABE: {ok:true, ui, screens:[{screen, title, icon}]} | {ok:true, ui, view} | core.fn_app_refusal(...)
--   Tests: tests/db/core/test_fn_app_screen.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_screen(p text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_body   jsonb;
    v_ver    jsonb;
    v_chat   text;
    v_sender jsonb;
    v_pid    text;
    v_screen text;
    v_params jsonb;
    v_reg    record;
    v_res    jsonb;
    v_probe  jsonb;
    v_nav    jsonb := '[]'::jsonb;
    v_shell  jsonb := to_jsonb(ARRAY['core.app.title', 'core.app.reload', 'core.app.gap', 'core.app.nothing',
                                     'core.fmt.empty', 'core.fmt.default_suffix', 'core.fmt.yes',
                                     'core.fmt.no', 'core.fmt.removed']);
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN core.fn_app_refusal('forbidden');
    END IF;
    BEGIN
        v_body := p::jsonb;
    EXCEPTION WHEN OTHERS THEN
        v_body := NULL;
    END;
    IF jsonb_typeof(v_body) IS DISTINCT FROM 'object' THEN
        RETURN core.fn_app_refusal('malformed');
    END IF;

    v_ver := core.fn_app_verify_init_data(v_body->>'init_data');
    IF (v_ver->>'ok') IS DISTINCT FROM 'true' THEN
        RETURN core.fn_app_refusal(v_ver->>'code');
    END IF;
    v_chat   := v_ver->>'telegram_user_id';
    v_sender := agent.fn_resolve_sender((v_ver->>'telegram_user_id')::bigint);
    IF (v_sender->>'found') IS DISTINCT FROM 'true' THEN
        RETURN core.fn_app_refusal('unknown');
    END IF;
    v_pid := v_sender->>'person_id';
    IF core.fn_config_get('core', 'app', 'enabled') IS DISTINCT FROM 'true' THEN
        RETURN core.fn_app_refusal('disabled', v_chat);
    END IF;
    IF core.fn_config_get('core', 'app', 'audience') IS DISTINCT FROM 'household'
       AND (v_sender->>'role') IS DISTINCT FROM 'owner' THEN
        RETURN core.fn_app_refusal('not_allowed', v_chat);
    END IF;

    v_screen := NULLIF(v_body->>'screen', '');
    v_params := CASE WHEN jsonb_typeof(v_body->'params') = 'object' THEN v_body->'params' ELSE '{}'::jsonb END;

    IF v_screen IS NULL THEN
        FOR v_reg IN SELECT s.screen, s.package, s.handler_fn, s.icon FROM core.app_screens s ORDER BY s.ord, s.screen LOOP
            CONTINUE WHEN NOT core.fn_package_active(v_reg.package)
                       OR to_regprocedure(v_reg.handler_fn || '(jsonb)') IS NULL;
            BEGIN
                EXECUTE format('SELECT %s($1)', v_reg.handler_fn) INTO v_probe
                  USING jsonb_build_object('person_id', v_pid, 'params', jsonb_build_object('probe', true));
                CONTINUE WHEN (v_probe->>'ok') IS DISTINCT FROM 'true' OR (v_probe->>'empty') IS DISTINCT FROM 'false';
            EXCEPTION WHEN OTHERS THEN
                CONTINUE;
            END;
            v_nav := v_nav || jsonb_build_array(jsonb_build_object(
                'screen', v_reg.screen,
                'title',  core.fn_ui_tpl(v_reg.package || '.app.screen.' || v_reg.screen),
                'icon',   v_reg.icon));
        END LOOP;
        RETURN jsonb_build_object('ok', true, 'screens', v_nav,
            'ui', agent.fn_ui_texts_for(jsonb_build_object('chat_id', v_chat, 'keys', v_shell, 'doc', v_nav)));
    END IF;

    SELECT s.screen, s.package, s.handler_fn INTO v_reg FROM core.app_screens s WHERE s.screen = v_screen;
    IF NOT FOUND THEN
        RETURN core.fn_app_refusal('unknown_screen', v_chat);
    END IF;
    IF NOT core.fn_package_active(v_reg.package) OR to_regprocedure(v_reg.handler_fn || '(jsonb)') IS NULL THEN
        RETURN core.fn_app_refusal('unavailable', v_chat);
    END IF;
    BEGIN
        EXECUTE format('SELECT %s($1)', v_reg.handler_fn) INTO v_res
          USING jsonb_build_object('person_id', v_pid, 'params', v_params - 'probe');
    EXCEPTION WHEN OTHERS THEN
        RETURN core.fn_app_refusal('error', v_chat);
    END;
    IF jsonb_typeof(v_res) IS DISTINCT FROM 'object' THEN
        RETURN core.fn_app_refusal('error', v_chat);
    END IF;
    IF (v_res->>'ok') IS DISTINCT FROM 'true' THEN
        RETURN core.fn_app_refusal(CASE WHEN v_res->>'code' IN ('forbidden', 'unavailable') THEN v_res->>'code'
                                        ELSE 'error' END, v_chat);
    END IF;
    RETURN jsonb_build_object('ok', true, 'view', v_res,
        'ui', agent.fn_ui_texts_for(jsonb_build_object('chat_id', v_chat, 'keys', v_shell, 'doc', v_res)));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_app_screen(text) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_app_screen(text) FROM context_ro;
    END IF;
END $$;
