-- ============================================================
-- core.fn_app_screen (READ, Dispatcher) — der eine Eingang der Mini-App „Übersicht“ (docs/package-contract.md §3.12)
--   Die Seite schickt per POST {init_data, screen?, params?} (roh als Text, der Workflow reicht ihn ungeprueft durch).
--   Kette, jede Stufe lehnt ueber core.fn_app_refusal ab (nie ein RAISE, sonst ein Owner-Alert je Muell-Anfrage):
--     Frei-SQL-Sitzung -> forbidden; Body kein JSON-Objekt -> malformed; initData (core.fn_app_verify_init_data) ->
--     malformed/bad_signature/expired/no_secret; Person selbst aufloesen (agent.fn_resolve_sender, Zero-Trust: eine
--     person_id im Body zaehlt nie) -> unknown; core.config app.enabled (fail-closed: fehlt die Zeile = aus) ->
--     disabled; app.audience ('household' = alle aufgeloesten Personen, sonst nur der Owner) -> not_allowed. Das ist die
--     Zugangsfrage (Rolle aus fn_resolve_sender); WAS jemand sieht, entscheidet allein der Handler ueber
--     core.fn_app_sees_household.
--   Ohne screen: Navigation + Startseiten-Banner aus core.fn_app_nav (Bildschirme aktiver Pakete, deren probe nicht leer
--     ist; Banner nur aus der probe-Antwort); Titel-Key <pkg>.app.screen.<screen>.
--   Mit screen: Registry -> unknown_screen, Paket inaktiv/Handler fehlt -> unavailable, Handler wirft -> error,
--     Handler lehnt ab -> sein code. Der Handler bekommt {person_id, params} und loest die Rolle SELBST auf.
--   view.banners setzt immer der Dispatcher: die Startseite (erster Bildschirm der Navigation, auch beim Einzelabruf =
--     Tab zurueck) bekommt die eingesammelten Banner, jede andere Seite []; Banner der vollen Handler-View zaehlen nie.
--   ui = agent.fn_ui_texts_for fuer die Person mit allen Keys der Antwort + den Shell-Keys (core.app.*, core.fmt.*;
--     core.app.sum = „zusammen {sum}“, mit dem der Renderer jede section.value zeigt)
--     + date_short = {from, to}: Datums-Kurzform der Mini-App (Mini-App UX 2026-10-30): ein Datum in [heute - 3 Monate,
--     heute + 9 Monate) zeigt der Renderer ohne Jahr; heute = core.fn_today (Haushalts-Zeitzone, nicht die Geraeteuhr),
--     asymmetrisch, damit kein „15.11." zwei Jahre meinen kann. Chat/HITL/Cron setzen es nie (dort immer mit Jahr).
--   INVOKER unter der Host-Credential (Muster core.fn_dispatch_callback); handler_fn ist installer-geschrieben und per
--   CHECK schema-qualifiziert, nie Caller-Input.
--   p: Request-Body als Text
--   RUECKGABE: {ok:true, ui, screens:[{screen, title, icon}], first?:{screen, view}} | {ok:true, ui, view} |
--              core.fn_app_refusal(...); jede unerwartete Ausnahme -> core.fn_app_refusal('error') (Notnetz).
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
    v_nav    jsonb;
    v_first  jsonb;
    v_prev   record;
    v_home   boolean;
    v_short  jsonb := jsonb_build_object('date_short', jsonb_build_object(
                          'from', to_char(core.fn_today() - interval '3 months', 'YYYY-MM-DD'),
                          'to', to_char(core.fn_today() + interval '9 months', 'YYYY-MM-DD')));
    v_shell  jsonb := to_jsonb(ARRAY['core.app.title', 'core.app.reload', 'core.app.gap', 'core.app.nothing', 'core.app.sum',
                                     'core.fmt.empty', 'core.fmt.default_suffix', 'core.fmt.yes',
                                     'core.fmt.no', 'core.fmt.removed']);
BEGIN
  BEGIN  -- Notnetz am Ende: der Eingang wirft NIE (Internet-Muell darf keinen Owner-Alert ausloesen)
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
        v_nav := core.fn_app_nav(v_pid);
        -- Der erste Bildschirm kommt gleich mit (eine Anfrage beim Oeffnen statt zwei); scheitert er, laedt die Seite
        -- ihn wie jeden anderen nach.
        IF jsonb_array_length(v_nav->'screens') > 0 THEN
            SELECT s.handler_fn INTO v_reg FROM core.app_screens s WHERE s.screen = v_nav->'screens'->0->>'screen';
            BEGIN
                EXECUTE format('SELECT %s($1)', v_reg.handler_fn) INTO v_res
                  USING jsonb_build_object('person_id', v_pid, 'params', '{}'::jsonb);
                IF jsonb_typeof(v_res) = 'object' AND (v_res->>'ok') = 'true' THEN
                    v_first := jsonb_build_object('screen', v_nav->'screens'->0->>'screen',
                                                  'view', v_res || jsonb_build_object('banners', v_nav->'banners'));
                END IF;
            EXCEPTION WHEN OTHERS THEN
                v_first := NULL;
            END;
        END IF;
        v_nav := v_nav->'screens';
        RETURN jsonb_build_object('ok', true, 'screens', v_nav)
            || CASE WHEN v_first IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('first', v_first) END
            || jsonb_build_object('ui', agent.fn_ui_texts_for(jsonb_build_object('chat_id', v_chat, 'keys', v_shell,
                                                                                  'doc', jsonb_build_array(v_nav, v_first))) || v_short);
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
    -- Startseite (auch Tab zurueck) traegt die eingesammelten Banner, jede andere Seite keine. Startseite = kein frueherer
    -- Bildschirm (ord, screen) ist fuer diese Person nicht leer; erst dann alle probes (fn_app_nav), sonst bricht die
    -- Suche beim ersten nicht-leeren Vorgaenger ab (ein Reiter-Wechsel kostet nicht die Arbeit aller Bildschirme).
    v_home := true;
    FOR v_prev IN SELECT s.package, s.handler_fn FROM core.app_screens s
                   WHERE (s.ord, s.screen) < (SELECT s2.ord, s2.screen FROM core.app_screens s2 WHERE s2.screen = v_screen)
                   ORDER BY s.ord, s.screen LOOP
        CONTINUE WHEN NOT core.fn_package_active(v_prev.package) OR to_regprocedure(v_prev.handler_fn || '(jsonb)') IS NULL;
        BEGIN
            EXECUTE format('SELECT %s($1)', v_prev.handler_fn) INTO v_nav
              USING jsonb_build_object('person_id', v_pid, 'params', jsonb_build_object('probe', true));
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;
        END;
        IF jsonb_typeof(v_nav) = 'object' AND (v_nav->>'ok') = 'true' AND (v_nav->>'empty') = 'false' THEN
            v_home := false;
            EXIT;
        END IF;
    END LOOP;
    v_res := v_res || jsonb_build_object('banners',
        CASE WHEN v_home THEN core.fn_app_nav(v_pid)->'banners' ELSE '[]'::jsonb END);
    RETURN jsonb_build_object('ok', true, 'view', v_res,
        'ui', agent.fn_ui_texts_for(jsonb_build_object('chat_id', v_chat, 'keys', v_shell, 'doc', v_res)) || v_short);
  EXCEPTION WHEN OTHERS THEN
    BEGIN
        RETURN core.fn_app_refusal('error', v_chat);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'code', 'error');
    END;
  END;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_app_screen(text) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_app_screen(text) FROM context_ro;
    END IF;
END $$;
