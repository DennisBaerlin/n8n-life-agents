-- ============================================================
-- core.fn_release_card(p) (read-only, MERKT NICHTS — Update-Hinweis 2026-10-24)
--   Entscheidet, ob der Owner eine Release-Karte bekommt, und baut sie (Text + inline_keyboard) in seiner Sprache.
--   Aufrufer: der root-Check `lifeagents update --check` (provisioning/lib/update_runner.sh) mit dem jq-Auszug von
--   GET /repos/<slug>/releases. Gemerkt wird ERST nach erfolgreichem Senden (core.fn_release_card_sent) — ein
--   gescheiterter Send heisst: beim naechsten Check erneut.
--   Faellig, wenn: Schalter config feature.update_check = 'true' (fail-closed) UND installed ein stabiles Tag (nicht
--   'dev') UND es stabile Releases > installed gibt (keine Drafts/Prereleases/Nicht-SemVer; mit require_signature nur
--   solche mit Asset 'SHA256SUMS.sig') UND fuer das neueste noch keine Karte ging (Latch release_update/<tag>).
--   Text: Titel + die Kurzfassungen der hoechstens 3 neuesten Releases (core.fn_release_intro) + Hinweis.
--   Knoepfe: [Jetzt aktualisieren] (upd:now:<tag>, core.fn_handle_update_cb) + Link [Alle Aenderungen] (nur https).
--   p: {installed, releases:[{tag, draft, prerelease, body, html_url, assets:[name]}], require_signature?}
--   RUECKGABE: {due:false, reason:'disabled'|'not_release'|'invalid'|'up_to_date'|'notified'}
--            | {due:true, tag, text, keyboard:[[{text,callback_data}],[{text,url}]]}
--   Nie RAISE. INVOKER (Aufrufer = root ueber runuser postgres; db_test als Superuser).
--   Tests: tests/db/core/test_fn_release_card.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_release_card(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_inst   text;
    v_req    boolean;
    v_newer  jsonb;
    v_latest jsonb;
    v_lang   text;
    v_items  text;
    v_text   text;
    v_kb     jsonb;
BEGIN
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('due', false, 'reason', 'invalid');
    END IF;
    IF NOT COALESCE(core.fn_config_get('core', 'feature', 'update_check') = 'true', false) THEN
        RETURN jsonb_build_object('due', false, 'reason', 'disabled');
    END IF;
    v_inst := p->>'installed';
    IF core.fn_semver_cmp(v_inst, v_inst) IS NULL THEN
        RETURN jsonb_build_object('due', false, 'reason', 'not_release');
    END IF;
    IF jsonb_typeof(p->'releases') IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object('due', false, 'reason', 'invalid');
    END IF;
    v_req := COALESCE(p->'require_signature' = 'true'::jsonb, false);

    SELECT jsonb_agg(e ORDER BY (regexp_match(e->>'tag', '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'))::int[] DESC)
      INTO v_newer
      FROM jsonb_array_elements(p->'releases') e
     WHERE jsonb_typeof(e) = 'object'
       AND core.fn_semver_cmp(e->>'tag', v_inst) = 1
       AND NOT COALESCE(e->'draft' = 'true'::jsonb, false)
       AND NOT COALESCE(e->'prerelease' = 'true'::jsonb, false)
       AND (NOT v_req OR (jsonb_typeof(e->'assets') = 'array' AND e->'assets' ? 'SHA256SUMS.sig'));
    IF v_newer IS NULL THEN
        RETURN jsonb_build_object('due', false, 'reason', 'up_to_date');
    END IF;
    v_latest := v_newer->0;

    IF EXISTS (SELECT 1 FROM core.notification_state n
                WHERE n.source = 'release_update' AND n.key = v_latest->>'tag' AND n.state = 'fired') THEN
        RETURN jsonb_build_object('due', false, 'reason', 'notified', 'tag', v_latest->>'tag');
    END IF;

    v_lang := agent.fn_person_lang(NULL)->>'lang';   -- NULL = Owner (Person -> Owner -> en)
    -- Eine Zeile je Release: '• <tag>: <Kurzfassung>' (reine Formatierung, sprachneutral -> kein Katalog-Key)
    SELECT string_agg('• ' || (e->>'tag')
                      || CASE WHEN core.fn_release_intro(e->>'body') <> '' THEN ': ' || core.fn_release_intro(e->>'body') ELSE '' END,
                      E'\n' ORDER BY o)
      INTO v_items
      FROM jsonb_array_elements(v_newer) WITH ORDINALITY AS t(e, o)
     WHERE o <= 3;

    v_text := core.fn_ui_text('core.update.card.title', v_lang,
                  jsonb_build_object('tag', v_latest->>'tag', 'installed', v_inst))
              || E'\n\n' || v_items
              || E'\n\n' || core.fn_ui_text('core.update.card.hint', v_lang);

    v_kb := jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'text', core.fn_ui_text('core.update.card.button', v_lang),
                'callback_data', 'upd:now:' || (v_latest->>'tag'))));
    IF COALESCE(v_latest->>'html_url', '') ~ '^https://' THEN
        v_kb := v_kb || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                    'text', core.fn_ui_text('core.update.card.link', v_lang),
                    'url', v_latest->>'html_url')));
    END IF;

    RETURN jsonb_build_object('due', true, 'tag', v_latest->>'tag', 'text', v_text, 'keyboard', v_kb);
END;
$$;
