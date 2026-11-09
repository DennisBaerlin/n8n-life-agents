-- ============================================================
-- core.fn_update_report(p) (read-only — Update-Hinweis 2026-10-24, Fehler-Hilfe auf Owner-Wunsch)
--   Text + Knoepfe JEDER Meldung des root-Runners zu einem Auftrag (core.update_requests), in der Sprache des Owners.
--   Die EINE Adresse der Hilfe-Logik (Runner-Meldung im Chat und `lifeagents doctor`).
--   Jede Ergebnis-Meldung beantwortet drei Fragen: Was ist passiert? Laeuft mein System noch? Was kann ich tun?
--   -> Kopf-Text je Klasse (core.update.<klasse> bzw. core.update.fail.<klasse>) + nummerierte Schritte
--   (core.update.todo.*) + ggf. technische Details/Protokoll-Pfad.
--   Klassen (aus outcome, reason_code, changed, bot_up):
--     done | already_current | superseded | held | partial
--     done_not_ready = installiert, aber der Bot antwortet nicht (kein Knopf, der Text nennt `lifeagents doctor`)
--     unchanged  = failed, changed=false (Netz, Limit, Platz, Sperre, ...): System unveraendert
--     security   = failed mit signature/checksum: NICHT installiert, nie wiederholen, melden
--     midway     = failed, changed=true/unbekannt, Bot laeuft: Wiederholen setzt fort, sonst Rueckweg
--     interrupted= Runner starb mittendrin (Neustart), Bot laeuft
--     bot_down   = wie midway/interrupted, aber n8n nicht bereit -> KEINE Callback-Knoepfe (wuerden ins Leere tippen),
--                  nur Terminal-Schritte; URL-Knoepfe (Hilfe, Problem melden) gehen auch ohne Bot.
--   Knoepfe: [Erneut versuchen] (upd:retry:<tag>) nur bei laufendem Bot und core.fn_update_retry_allowed;
--     [Hilfe] -> help_url#<klasse>; [Problem melden] nur bei security -> github.com/<slug>/security/advisories/new
--     (private Meldung, Issues sind aus; ohne vorausgefuellten Text, also nie detail/Log im Link).
--   Phase progress_plan: alle Texte der Fortschritts-Nachricht samt Balken, fertig gerendert. Der Runner liest sie einmal vor
--   dem Update, denn danach ist die DB zeitweise weg. Prozent = Beginn des Schritts, fest geschaetzt; der Helfer rechnet nichts.
--   p: {request_id, phase:'start'|'result'|'progress_plan', bot_up?(Default true), help_url?, repo_slug?, backup?, log?,
--       missing?, failed?, latest?}
--   RUECKGABE: {text, keyboard:[[...]], class} — unbekannter Auftrag -> {text:'', keyboard:[]}. Nie RAISE.
--     progress_plan: {start:{pct,text,stopped}, stages:{<code>:{pct,text,stopped}}, done:{pct,text}}
--   INVOKER (root ueber runuser postgres). Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_update_report(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_r       core.update_requests%ROWTYPE;
    v_id      bigint;
    v_lang    text;
    v_bot_up  boolean := COALESCE(p->'bot_up' <> 'false'::jsonb, true);
    v_class   text;
    v_head    text;
    v_stage_key  text;
    v_reason_key text;
    v_todo    text[] := '{}';
    v_text    text;
    v_retry   boolean;
    v_params  jsonb;
    v_kb      jsonb := '[]'::jsonb;
    v_urls    jsonb := '[]'::jsonb;
    v_plan    jsonb;
    v_filled  text;
    v_empty   text;
    v_help    text := CASE WHEN COALESCE(p->>'help_url', '') ~ '^https://[^\s#]+$' THEN p->>'help_url' END;
    v_slug    text := CASE WHEN COALESCE(p->>'repo_slug', '') ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' THEN p->>'repo_slug' END;
    -- Die eine Adresse fuer Schritt-Code -> Prozent + Text. Neuer ui_step-Code: hier eintragen und Key anlegen.
    v_stages  jsonb := '[
        {"code":"download",  "pct":3,  "key":"core.update.stage.download"},
        {"code":"verify",    "pct":8,  "key":"core.update.stage.verify"},
        {"code":"preflight", "pct":12, "key":"core.update.stage.preflight"},
        {"code":"base",      "pct":15, "key":"core.update.stage.base"},
        {"code":"backup",    "pct":25, "key":"core.update.stage.backup"},
        {"code":"postgres",  "pct":40, "key":"core.update.stage.postgres"},
        {"code":"n8n",       "pct":45, "key":"core.update.stage.n8n"},
        {"code":"gateway",   "pct":62, "key":"core.update.stage.gateway"},
        {"code":"schema",    "pct":66, "key":"core.update.stage.schema"},
        {"code":"access",    "pct":74, "key":"core.update.stage.access"},
        {"code":"workflows", "pct":77, "key":"core.update.stage.workflows"},
        {"code":"packages",  "pct":85, "key":"core.update.stage.packages"},
        {"code":"cli",       "pct":92, "key":"core.update.stage.cli"},
        {"code":"final",     "pct":95, "key":"core.update.stage.final"}]'::jsonb;
BEGIN
    BEGIN
        v_id := (p->>'request_id')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_id := NULL;
    END;
    SELECT * INTO v_r FROM core.update_requests WHERE id = v_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('text', '', 'keyboard', '[]'::jsonb, 'class', NULL);
    END IF;

    v_lang := agent.fn_person_lang(NULL)->>'lang';   -- NULL = Owner
    -- Codes -> GANZE Katalog-Keys (locale_lint 8: SQL nennt Keys nur vollstaendig); Unbekanntes -> .unknown
    v_stage_key := COALESCE((SELECT s->>'key' FROM jsonb_array_elements(v_stages) s WHERE s->>'code' = v_r.stage),
                            'core.update.stage.unknown');
    v_reason_key := CASE v_r.reason_code
        WHEN 'net'       THEN 'core.update.reason.net'        WHEN 'rate_limit' THEN 'core.update.reason.rate_limit'
        WHEN 'not_found' THEN 'core.update.reason.not_found'  WHEN 'checksum'   THEN 'core.update.reason.checksum'
        WHEN 'signature' THEN 'core.update.reason.signature'  WHEN 'disk'       THEN 'core.update.reason.disk'
        WHEN 'backup'    THEN 'core.update.reason.backup'     WHEN 'db'         THEN 'core.update.reason.db'
        WHEN 'n8n_start' THEN 'core.update.reason.n8n_start'  WHEN 'package'    THEN 'core.update.reason.package'
        WHEN 'locked'    THEN 'core.update.reason.locked'     WHEN 'downgrade'  THEN 'core.update.reason.downgrade'
        ELSE 'core.update.reason.unknown' END;
    v_params := jsonb_build_object(
        'tag',     v_r.tag,
        'from',    COALESCE(v_r.from_version, '?'),
        'latest',  COALESCE(p->>'latest', ''),
        'stage',   core.fn_ui_text(v_stage_key, v_lang),
        'reason',  core.fn_ui_text(v_reason_key, v_lang),
        'backup',  COALESCE(NULLIF(p->>'backup', ''), core.fn_ui_text('core.update.no_backup', v_lang)),
        'missing', COALESCE(p->>'missing', ''),
        'failed',  COALESCE(p->>'failed', ''),
        'detail',  COALESCE(v_r.detail, ''),
        'log',     COALESCE(p->>'log', ''));

    IF p->>'phase' = 'progress_plan' THEN
        v_filled := core.fn_ui_text('core.update.bar.filled', v_lang);
        v_empty  := core.fn_ui_text('core.update.bar.empty', v_lang);
        SELECT jsonb_object_agg(s->>'code', jsonb_build_object(
                   'pct', (s->>'pct')::int,
                   'text', core.fn_ui_text('core.update.progress', v_lang, jsonb_build_object(
                       'tag', v_r.tag, 'pct', s->>'pct', 'stage', core.fn_ui_text(s->>'key', v_lang),
                       'bar', repeat(v_filled, (s->>'pct')::int / 10) || repeat(v_empty, 10 - (s->>'pct')::int / 10))),
                   'stopped', core.fn_ui_text('core.update.progress.stopped', v_lang, jsonb_build_object(
                       'tag', v_r.tag, 'pct', s->>'pct',
                       'bar', repeat(v_filled, (s->>'pct')::int / 10) || repeat(v_empty, 10 - (s->>'pct')::int / 10)))))
          INTO v_plan
          FROM jsonb_array_elements(v_stages) s;
        RETURN jsonb_build_object(
            'stages', v_plan,
            'start', jsonb_build_object(
                'pct', 0,
                'text', core.fn_ui_text('core.update.progress', v_lang, jsonb_build_object(
                    'tag', v_r.tag, 'pct', '0', 'stage', core.fn_ui_text('core.update.stage.start', v_lang), 'bar', repeat(v_empty, 10))),
                'stopped', core.fn_ui_text('core.update.progress.stopped', v_lang, jsonb_build_object(
                    'tag', v_r.tag, 'pct', '0', 'bar', repeat(v_empty, 10)))),
            'done', jsonb_build_object(
                'pct', 100,
                'text', core.fn_ui_text('core.update.progress.done', v_lang, jsonb_build_object(
                    'tag', v_r.tag, 'pct', '100', 'bar', repeat(v_filled, 10)))));
    END IF;

    -- Die Start-Meldung ruft nur noch ein Runner ohne Fortschritts-Helfer: er laeuft beim Umstieg neben dieser Fassung.
    IF COALESCE(p->>'phase', 'result') = 'start' THEN
        RETURN jsonb_build_object('text', core.fn_ui_text('core.update.running', v_lang, v_params),
                                  'keyboard', '[]'::jsonb, 'class', 'running');
    END IF;

    v_class := CASE
        WHEN v_r.outcome = 'succeeded' AND NOT v_bot_up THEN 'done_not_ready'
        WHEN v_r.outcome = 'succeeded'       THEN 'done'
        WHEN v_r.outcome = 'already_current' THEN 'already_current'
        WHEN v_r.outcome = 'superseded'      THEN 'superseded'
        WHEN v_r.outcome = 'held'            THEN 'held'
        WHEN v_r.outcome = 'partial'         THEN 'partial'
        WHEN v_r.outcome = 'failed' AND COALESCE(v_r.reason_code, '') IN ('signature', 'checksum') THEN 'security'
        WHEN v_r.outcome = 'failed' AND v_r.changed IS FALSE THEN 'unchanged'
        WHEN NOT v_bot_up                    THEN 'bot_down'
        WHEN v_r.outcome = 'interrupted'     THEN 'interrupted'
        WHEN v_r.outcome = 'failed'          THEN 'midway'   -- changed=true oder unbekannt -> vorsichtig
        ELSE NULL
    END;
    IF v_class IS NULL THEN   -- noch offen / unbekannter Zustand
        RETURN jsonb_build_object('text', '', 'keyboard', '[]'::jsonb, 'class', NULL);
    END IF;

    v_head := CASE v_class
        WHEN 'done'            THEN 'core.update.done'
        WHEN 'done_not_ready'  THEN 'core.update.done_not_ready'
        WHEN 'already_current' THEN 'core.update.already_current'
        WHEN 'superseded'      THEN 'core.update.superseded'
        WHEN 'held'            THEN 'core.update.held'
        WHEN 'partial'         THEN 'core.update.partial'
        WHEN 'unchanged'       THEN 'core.update.fail.unchanged'
        WHEN 'security'        THEN 'core.update.fail.security'
        WHEN 'midway'          THEN 'core.update.fail.midway'
        WHEN 'interrupted'     THEN 'core.update.fail.interrupted'
        ELSE                        'core.update.fail.bot_down'
    END;
    v_retry := v_bot_up AND v_class IN ('unchanged', 'partial', 'midway', 'interrupted')
               AND core.fn_update_retry_allowed(v_r.tag);

    v_todo := CASE v_class
        WHEN 'unchanged'   THEN CASE WHEN v_r.reason_code = 'disk' THEN ARRAY['core.update.todo.disk'] ELSE '{}'::text[] END
                                || CASE WHEN v_retry THEN 'core.update.todo.retry' ELSE 'core.update.todo.later' END::text
        WHEN 'security'    THEN ARRAY['core.update.todo.security']
        WHEN 'held'        THEN ARRAY['core.update.todo.held']
        WHEN 'partial'     THEN CASE WHEN v_retry THEN ARRAY['core.update.todo.retry'] ELSE '{}'::text[] END
                                || 'core.update.todo.doctor'::text
        WHEN 'midway'      THEN ARRAY[CASE WHEN v_retry THEN 'core.update.todo.retry' ELSE 'core.update.todo.terminal_update' END,
                                      'core.update.todo.rollback']
        WHEN 'interrupted' THEN ARRAY[CASE WHEN v_retry THEN 'core.update.todo.retry' ELSE 'core.update.todo.terminal_update' END,
                                      'core.update.todo.rollback']
        WHEN 'bot_down'    THEN ARRAY['core.update.todo.terminal_update', 'core.update.todo.rollback']
        ELSE '{}'::text[]
    END;

    v_text := core.fn_ui_text(v_head, v_lang, v_params);
    IF cardinality(v_todo) > 0 THEN
        v_text := v_text || E'\n\n' || core.fn_ui_text('core.update.todo.heading', v_lang) || E'\n'
                  || (SELECT string_agg(o || '. ' || core.fn_ui_text(k, v_lang, v_params), E'\n' ORDER BY o)
                        FROM unnest(v_todo) WITH ORDINALITY AS t(k, o));
    END IF;
    IF v_class NOT IN ('done', 'done_not_ready', 'already_current', 'superseded') THEN
        IF v_r.detail IS NOT NULL THEN
            v_text := v_text || E'\n\n' || core.fn_ui_text('core.update.detail', v_lang, v_params);
        END IF;
        IF COALESCE(p->>'log', '') <> '' THEN
            v_text := v_text || E'\n' || core.fn_ui_text('core.update.log', v_lang, v_params);
        END IF;
    END IF;

    IF v_retry THEN
        v_kb := v_kb || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                    'text', core.fn_ui_text('core.update.button.retry', v_lang),
                    'callback_data', 'upd:retry:' || v_r.tag)));
    END IF;
    IF v_help IS NOT NULL AND v_class NOT IN ('done', 'done_not_ready', 'already_current', 'superseded') THEN
        v_urls := v_urls || jsonb_build_object('text', core.fn_ui_text('core.update.button.help', v_lang),
                                               'url', v_help || '#' || replace(v_class, '_', '-'));
    END IF;
    IF v_class = 'security' AND v_slug IS NOT NULL THEN
        v_urls := v_urls || jsonb_build_object('text', core.fn_ui_text('core.update.button.report', v_lang),
                    'url', 'https://github.com/' || v_slug || '/security/advisories/new');
    END IF;
    IF jsonb_array_length(v_urls) > 0 THEN
        v_kb := v_kb || jsonb_build_array(v_urls);
    END IF;

    RETURN jsonb_build_object('text', v_text, 'keyboard', v_kb, 'class', v_class);
END;
$$;

-- Der einzige Aufrufer ist oben entfallen. Hier statt in einem V__ gedroppt: V__ laeuft vor den R__, und ein dazwischen
-- abgebrochenes Update fiele mit der alten Fassung dieser fn gerade beim Melden des Fehlers aus.
DROP FUNCTION IF EXISTS core.fn_url_encode(text);
