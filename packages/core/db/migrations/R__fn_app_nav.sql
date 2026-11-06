-- ============================================================
-- core.fn_app_nav(p_pid text) — Navigation + Startseiten-Banner der Mini-App (READ, intern fuer core.fn_app_screen)
--   Ruft je Bildschirm eines aktiven Pakets (core.app_screens, ord) den Handler mit params.probe=true und nimmt nur
--   nicht-leere Bildschirme auf. Banner kommen NUR aus dieser probe-Antwort ({ok, empty:false, banners:[…]},
--   docs/package-contract.md §3.12); empty=true verwirft sie. Jedes Banner wird EINZELN geprueft (ausserhalb des
--   Exception-Blocks, ein schlechtes Element kostet nie den Bildschirm): state alert|warn, icon nicht leer, text ein
--   {kind:'tpl'}-Verweis, target NULL oder {screen} aus dieser Navigation. Sortierung alert vor warn, dann ord, dann
--   Position im Handler. Ein werfender Handler fehlt in der Navigation, eine kaputte Banner-Liste kostet nur die Banner.
--   ok-Banner (UX-Gesamtkonzept 2026-10-31, P4 — das eine gruene Signal der App): bleibt nach dem Einsammeln kein
--   alert/warn uebrig, hat die Navigation >= 1 Bildschirm UND gab es keinen Fehler, kommt genau EIN Banner
--   {state ok, icon check, text core.app.all_good, target null}. Fehler = Handler wirft, Antwort kein Objekt, ok<>true
--   ausser code forbidden/unavailable (Bildschirm fuer diese Person nicht da), ok ohne boolesches empty, banners kein
--   Array, oder ein Roh-Element alert/warn, das die Einzelpruefung nicht besteht — ein verlorener Hinweis darf nie
--   „Alles in Ordnung“ ergeben. ok-Banner der Handler selbst werden weiter verworfen. Eine Pille an einer Zeile ohne
--   Banner (Dauerzustand wie „Notreserve noch nicht voll“, Owner-Entscheid D3) haelt das ok-Banner bewusst nicht auf:
--   Banner = jetzt handeln, Pille = Zustand der Zeile.
--   p_pid = die vom Dispatcher aufgeloeste Person (Zero-Trust); erste Anweisung Frei-SQL-Schutz.
--   INVOKER unter der Host-Credential wie core.fn_app_screen; handler_fn ist installer-geschrieben (CHECK), nie Input.
--   RUECKGABE: {screens:[{screen, title:<tpl>, icon}], banners:[…alert/warn…] | [ok-Banner]} | {screens:[], banners:[]}
--              (Frei-SQL)
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
    v_failed  boolean := false;   -- ein Bildschirm hatte einen Fehler -> nie das ok-Banner
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
            v_failed := true;
            CONTINUE;
        END;
        IF jsonb_typeof(v_probe) IS DISTINCT FROM 'object'
           OR ((v_probe->>'ok') IS DISTINCT FROM 'true' AND v_probe->>'code' IS DISTINCT FROM 'forbidden'
               AND v_probe->>'code' IS DISTINCT FROM 'unavailable')
           OR ((v_probe->>'ok') = 'true' AND jsonb_typeof(v_probe->'empty') IS DISTINCT FROM 'boolean') THEN
            v_failed := true;
        END IF;
        CONTINUE WHEN jsonb_typeof(v_probe) IS DISTINCT FROM 'object'
                   OR (v_probe->>'ok') IS DISTINCT FROM 'true' OR (v_probe->>'empty') IS DISTINCT FROM 'false';
        v_nav := v_nav || jsonb_build_array(jsonb_build_object(
            'screen', v_reg.screen,
            'title',  core.fn_ui_tpl(v_reg.package || '.app.screen.' || v_reg.screen),
            'icon',   v_reg.icon));
        IF jsonb_typeof(v_probe->'banners') = 'array' THEN
            v_cand := v_cand || jsonb_build_array(jsonb_build_object('ord', v_reg.ord, 'banners', v_probe->'banners'));
        ELSIF v_probe ? 'banners' AND jsonb_typeof(v_probe->'banners') <> 'null' THEN
            v_failed := true;
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
    -- ein alert/warn-Roh-Element, das die Pruefung oben nicht bestand, ist ein verlorener Hinweis
    IF (SELECT count(*) FROM jsonb_array_elements(v_cand) c
          CROSS JOIN LATERAL jsonb_array_elements(c->'banners') e
         WHERE jsonb_typeof(e) = 'object' AND e->>'state' IN ('alert', 'warn')) > jsonb_array_length(v_banners) THEN
        v_failed := true;
    END IF;
    IF jsonb_array_length(v_banners) = 0 AND jsonb_array_length(v_nav) > 0 AND NOT v_failed THEN
        v_banners := jsonb_build_array(jsonb_build_object('state', 'ok', 'icon', 'check',
                       'text', core.fn_ui_tpl('core.app.all_good'), 'target', NULL));
    END IF;
    RETURN jsonb_build_object('screens', v_nav, 'banners', v_banners);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_app_nav(text) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_app_nav(text) FROM context_ro;
    END IF;
END $$;
