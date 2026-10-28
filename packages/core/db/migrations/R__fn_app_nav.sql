-- ============================================================
-- core.fn_app_nav(p_pid text) — Navigation + Startseiten-Banner der Mini-App (READ, intern fuer core.fn_app_screen)
--   Ruft je Bildschirm eines aktiven Pakets (core.app_screens, ord) den Handler mit params.probe=true und nimmt nur
--   nicht-leere Bildschirme auf. Banner kommen NUR aus dieser probe-Antwort ({ok, empty:false, banners:[…]},
--   docs/package-contract.md §3.12); empty=true verwirft sie. Jedes Banner wird EINZELN geprueft (ausserhalb des
--   Exception-Blocks, ein schlechtes Element kostet nie den Bildschirm): state alert|warn, icon nicht leer, text ein
--   {kind:'tpl'}-Verweis, target NULL oder {screen} aus dieser Navigation. Sortierung alert vor warn, dann ord, dann
--   Position im Handler. Ein werfender Handler fehlt in der Navigation, eine kaputte Banner-Liste kostet nur die Banner.
--   p_pid = die vom Dispatcher aufgeloeste Person (Zero-Trust); erste Anweisung Frei-SQL-Schutz.
--   INVOKER unter der Host-Credential wie core.fn_app_screen; handler_fn ist installer-geschrieben (CHECK), nie Input.
--   RUECKGABE: {screens:[{screen, title:<tpl>, icon}], banners:[…]} | {screens:[], banners:[]} (Frei-SQL)
--   Tests: tests/db/core/test_fn_app_screen.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_nav(p_pid text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_reg    record;
    v_probe  jsonb;
    v_nav    jsonb := '[]'::jsonb;
    v_cand   jsonb := '[]'::jsonb;   -- [{ord, banners}] je nicht-leerem Bildschirm, Pruefung erst mit fertiger Navigation
    v_screens text[];
    v_banners jsonb;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('screens', '[]'::jsonb, 'banners', '[]'::jsonb);
    END IF;
    FOR v_reg IN SELECT s.screen, s.package, s.handler_fn, s.icon, s.ord FROM core.app_screens s ORDER BY s.ord, s.screen LOOP
        CONTINUE WHEN NOT core.fn_package_active(v_reg.package)
                   OR to_regprocedure(v_reg.handler_fn || '(jsonb)') IS NULL;
        BEGIN
            EXECUTE format('SELECT %s($1)', v_reg.handler_fn) INTO v_probe
              USING jsonb_build_object('person_id', p_pid, 'params', jsonb_build_object('probe', true));
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;
        END;
        CONTINUE WHEN jsonb_typeof(v_probe) IS DISTINCT FROM 'object'
                   OR (v_probe->>'ok') IS DISTINCT FROM 'true' OR (v_probe->>'empty') IS DISTINCT FROM 'false';
        v_nav := v_nav || jsonb_build_array(jsonb_build_object(
            'screen', v_reg.screen,
            'title',  core.fn_ui_tpl(v_reg.package || '.app.screen.' || v_reg.screen),
            'icon',   v_reg.icon));
        IF jsonb_typeof(v_probe->'banners') = 'array' THEN
            v_cand := v_cand || jsonb_build_array(jsonb_build_object('ord', v_reg.ord, 'banners', v_probe->'banners'));
        END IF;
    END LOOP;

    SELECT COALESCE(array_agg(n->>'screen'), '{}') INTO v_screens FROM jsonb_array_elements(v_nav) n;
    SELECT COALESCE(jsonb_agg(b.e ORDER BY b.e->>'state' = 'alert' DESC, (c->>'ord')::int, b.pos), '[]'::jsonb)
      INTO v_banners
      FROM jsonb_array_elements(v_cand) c
      CROSS JOIN LATERAL jsonb_array_elements(c->'banners') WITH ORDINALITY AS b(e, pos)
     WHERE jsonb_typeof(b.e) = 'object'
       AND b.e->>'state' IN ('alert', 'warn')
       AND COALESCE(b.e->>'icon', '') <> ''
       AND jsonb_typeof(b.e->'text') = 'object' AND b.e->'text'->>'kind' = 'tpl'
       AND (jsonb_typeof(COALESCE(b.e->'target', 'null'::jsonb)) = 'null'
            OR (jsonb_typeof(b.e->'target') = 'object' AND b.e->'target'->>'screen' = ANY (v_screens)));
    RETURN jsonb_build_object('screens', v_nav, 'banners', v_banners);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_app_nav(text) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_app_nav(text) FROM context_ro;
    END IF;
END $$;
