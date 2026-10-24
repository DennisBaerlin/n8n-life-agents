-- ============================================================
-- core.fn_render_welcome(p_lang text DEFAULT NULL) -> jsonb   (Install-UX-Phase 6 — die EINE Textquelle der Owner-Begruessung)
--   Zwei Konsumenten, ein Text: (a) der Orchestrator bei einem nackten /start des Owners (liest unter core_ro,
--   'Start onboarding read', mit der Sprache des Owners) und (b) der Installer direkt nach dem Pairing + _oc_finalize
--   (owner_connect.sh, Superuser, ohne Argument; erst dann sind echte Owner-chat_id + Re-Deploy durch, sonst liefe ein
--   frueher Knopf-Tipp ins Leere). Reiner Text OHNE Markdown (der n8n-Send escapt ohnehin, der Installer sendet ohne
--   parse_mode).
--   Sprache: p_lang (NULL/leer -> Sprache des Owners, agent.fn_person_lang); alle Texte aus dem Textkatalog
--   (core.ui_texts, Keys core.welcome.*, Paketnamen <pkg>.package.name; fehlender Key -> en, docs/package-contract.md §3.11).
--   kind  'new'  = Core-Haushalt noch offen (agent.guide_onboarding_state 'unknown'; dieselbe Regel wie das
--                  Core-first-Gate) -> Vorname + installierte Funktionen + naechster Schritt + 2 Core-Knoepfe.
--         'back' = Haushalt erledigt/uebersprungen -> kurzer Text, keine Knoepfe.
--   Installiert = core.package_registry status 'active' (Name aus dem Katalog, Fallback Paket-id; core zuerst);
--   'inactive' wird mit dem Einschalt-Befehl genannt; 'installing'/'installed' (abgebrochen) zaehlen nicht.
--   Vorname = family.metadata.facts.persons[] role 'owner' (fehlt -> generische Anrede).
--   Knopf-Vertrag (FEST): [onboarding:core:household, help:overview] — beide Core = immer gueltig; workflow_lint prueft
--     die Orchestrator-Knoepfe gegen genau diese callback_data-Liste (Anzahl/Reihenfolge der n8n-Knoepfe ist build-time
--     fest, nur Text/Data sind Ausdruecke); die Knopf-Texte kommen in derselben Sprache mit.
--   SECURITY INVOKER (core_ro liest agent+core ohnehin; Decision-Rule .claude/rules/sql.md), search_path gepinnt,
--   REVOKE PUBLIC; der core_ro-Grant lebt am Rollen-Ort util_create_core_ro.sql.
--   RUECKGABE: {ok:true, kind, lang, text, buttons:[{text, callback_data}]}
--   Tests: tests/db/core/test_fn_render_welcome.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_render_welcome(p_lang text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, agent, core
AS $$
DECLARE
    v_lang     TEXT;
    v_first    TEXT;
    v_new      BOOLEAN;
    v_has_pkg  BOOLEAN;
    v_active   TEXT;
    v_inactive TEXT;
    v_hi       TEXT;
    v_text     TEXT;
BEGIN
    -- Sprache: explizit (nur Katalog-Codes, sonst en) oder die des Owners (Kette Owner -> en).
    v_lang := CASE
        WHEN NULLIF(btrim(p_lang), '') IS NULL THEN agent.fn_person_lang(agent.fn_owner_person_id())->>'lang'
        WHEN EXISTS (SELECT 1 FROM core.ui_languages WHERE code = btrim(p_lang)) THEN btrim(p_lang)
        ELSE 'en' END;

    SELECT NULLIF(btrim(pp->>'first_name'), '') INTO v_first
    FROM agent.core_contexts c
         CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family' AND pp->>'role' = 'owner'
    LIMIT 1;

    v_new := EXISTS (SELECT 1 FROM agent.guide_onboarding_state WHERE status = 'unknown');
    v_has_pkg := EXISTS (SELECT 1 FROM core.package_registry WHERE status IN ('active', 'inactive') AND package <> 'core');

    -- Paketnamen aus dem Katalog (fehlt der Key -> Paket-id). Core zuerst (immer da — der Host ist mit dem System
    -- installiert), dann aktive Pakete nach Anzeigename.
    WITH n AS (
        SELECT r.package, r.status,
               COALESCE(NULLIF(core.fn_ui_text(r.package || '.package.name', v_lang), r.package || '.package.name'),
                        r.package) AS name
        FROM core.package_registry r
    )
    SELECT COALESCE(NULLIF(core.fn_ui_text('core.package.name', v_lang), 'core.package.name'), 'core')
           || COALESCE((SELECT ', ' || string_agg(n.name, ', ' ORDER BY n.name)
                        FROM n WHERE n.status = 'active' AND n.package <> 'core'), ''),
           (SELECT string_agg(core.fn_ui_text('core.welcome.inactive_item', v_lang,
                                  jsonb_build_object('name', n.name, 'package', n.package)), '; ' ORDER BY n.name)
            FROM n WHERE n.status = 'inactive' AND n.package <> 'core')
      INTO v_active, v_inactive;

    v_hi := core.fn_ui_text('core.welcome.installed', v_lang, jsonb_build_object('list', v_active))
            || CASE WHEN v_inactive IS NULL THEN ''
                    ELSE ' ' || core.fn_ui_text('core.welcome.inactive', v_lang, jsonb_build_object('list', v_inactive)) END;

    IF v_new THEN
        v_text := CASE WHEN v_first IS NULL THEN core.fn_ui_text('core.welcome.hello', v_lang)
                       ELSE core.fn_ui_text('core.welcome.hello_name', v_lang, jsonb_build_object('name', v_first)) END
            || E'\n\n' || core.fn_ui_text('core.welcome.intro', v_lang) || ' ' || v_hi
            || E'\n\n' || core.fn_ui_text('core.welcome.household_first', v_lang) || ' '
            || core.fn_ui_text(CASE WHEN v_first IS NULL THEN 'core.welcome.setup' ELSE 'core.welcome.setup_known' END, v_lang)
            || E'\n\n'
            -- Die DB kennt nur INSTALLIERTE Pakete, nicht die mitgelieferten: ohne jedes Zusatz-Paket ist sicher noch
            -- etwas dazunehmbar (Befehl direkt nennen), sonst verweist der Text auf /help (dessen Abschnitt „Weitere
            -- Funktionen" der Installer aus den Manifesten komponiert) — keine Behauptung, die nicht stimmen koennte.
            || core.fn_ui_text(CASE WHEN v_has_pkg THEN 'core.welcome.help_more' ELSE 'core.welcome.help_install' END, v_lang);
        RETURN jsonb_build_object('ok', true, 'kind', 'new', 'lang', v_lang, 'text', v_text,
            'buttons', jsonb_build_array(
                jsonb_build_object('text', core.fn_ui_text('core.welcome.btn_household', v_lang),
                                   'callback_data', 'onboarding:core:household'),
                jsonb_build_object('text', core.fn_ui_text('core.welcome.btn_help', v_lang),
                                   'callback_data', 'help:overview')));
    END IF;

    v_text := CASE WHEN v_first IS NULL THEN core.fn_ui_text('core.welcome.back', v_lang)
                   ELSE core.fn_ui_text('core.welcome.back_name', v_lang, jsonb_build_object('name', v_first)) END
        || ' ' || v_hi
        || E'\n\n' || core.fn_ui_text('core.welcome.back_hint', v_lang);
    RETURN jsonb_build_object('ok', true, 'kind', 'back', 'lang', v_lang, 'text', v_text, 'buttons', '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_render_welcome(text) FROM public;
