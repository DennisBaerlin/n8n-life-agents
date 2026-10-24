-- ============================================================
-- core.fn_update_report(p) (read-only — Update-Hinweis 2026-10-24, Fehler-Hilfe auf Owner-Wunsch)
--   Text + Knoepfe JEDER Meldung des root-Runners zu einem Auftrag (core.update_requests), in der Sprache des Owners.
--   Die EINE Adresse der Hilfe-Logik (Runner-Meldung im Chat und `lifeagents doctor`).
--   Jede Ergebnis-Meldung beantwortet drei Fragen: Was ist passiert? Laeuft mein System noch? Was kann ich tun?
--   -> Kopf-Text je Klasse (core.update.<klasse> bzw. core.update.fail.<klasse>) + nummerierte Schritte
--   (core.update.todo.*) + ggf. technische Details/Protokoll-Pfad.
--   Klassen (aus outcome, reason_code, changed, bot_up):
--     done | already_current | superseded | held | partial
--     unchanged  = failed, changed=false (Netz, Limit, Platz, Sperre, ...): System unveraendert
--     security   = failed mit signature/checksum: NICHT installiert, nie wiederholen, melden
--     midway     = failed, changed=true/unbekannt, Bot laeuft: Wiederholen setzt fort, sonst Rueckweg
--     interrupted= Runner starb mittendrin (Neustart), Bot laeuft
--     bot_down   = wie midway/interrupted, aber n8n nicht bereit -> KEINE Callback-Knoepfe (wuerden ins Leere tippen),
--                  nur Terminal-Schritte; URL-Knoepfe (Hilfe, Problem melden) gehen auch ohne Bot.
--   Knoepfe: [Erneut versuchen] (upd:retry:<tag>) nur bei laufendem Bot und core.fn_update_retry_allowed;
--     [Hilfe] -> help_url#<klasse>; [Problem melden] -> github.com/<slug>/issues/new mit Titel/Text NUR aus festen
--     Codes (Versionen, Klasse, Schritt, Grund) — nie detail/Log (koennen Domain, Pfade, Namen enthalten).
--     Der Issue-Text ist bewusst Englisch (Empfaenger = das Projekt, nicht der Nutzer).
--   p: {request_id, phase:'start'|'result', bot_up?(Default true), help_url?, repo_slug?, backup?, log?,
--       missing?, failed?, latest?}
--   RUECKGABE: {text, keyboard:[[...]], class} — unbekannter Auftrag -> {text:'', keyboard:[]}. Nie RAISE.
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
    v_help    text := CASE WHEN COALESCE(p->>'help_url', '') ~ '^https://[^\s#]+$' THEN p->>'help_url' END;
    v_slug    text := CASE WHEN COALESCE(p->>'repo_slug', '') ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' THEN p->>'repo_slug' END;
    v_report  boolean := false;
    v_title   text;
    v_body    text;
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
    v_stage_key := CASE v_r.stage
        WHEN 'preflight' THEN 'core.update.stage.preflight'  WHEN 'download'  THEN 'core.update.stage.download'
        WHEN 'base'      THEN 'core.update.stage.base'
        WHEN 'verify'    THEN 'core.update.stage.verify'     WHEN 'backup'    THEN 'core.update.stage.backup'
        WHEN 'postgres'  THEN 'core.update.stage.postgres'   WHEN 'n8n'       THEN 'core.update.stage.n8n'
        WHEN 'gateway'   THEN 'core.update.stage.gateway'    WHEN 'schema'    THEN 'core.update.stage.schema'
        WHEN 'access'    THEN 'core.update.stage.access'     WHEN 'workflows' THEN 'core.update.stage.workflows'
        WHEN 'packages'  THEN 'core.update.stage.packages'   WHEN 'cli'       THEN 'core.update.stage.cli'
        WHEN 'final'     THEN 'core.update.stage.final'
        ELSE 'core.update.stage.unknown' END;
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

    IF COALESCE(p->>'phase', 'result') = 'start' THEN
        RETURN jsonb_build_object('text', core.fn_ui_text('core.update.running', v_lang, v_params),
                                  'keyboard', '[]'::jsonb, 'class', 'running');
    END IF;

    v_class := CASE
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
                                      'core.update.todo.rollback', 'core.update.todo.report']
        WHEN 'interrupted' THEN ARRAY[CASE WHEN v_retry THEN 'core.update.todo.retry' ELSE 'core.update.todo.terminal_update' END,
                                      'core.update.todo.rollback', 'core.update.todo.report']
        WHEN 'bot_down'    THEN ARRAY['core.update.todo.terminal_update', 'core.update.todo.rollback', 'core.update.todo.report']
        ELSE '{}'::text[]
    END;
    -- [Problem melden] nur, wo der Nutzer allein nicht weiterkommt (kein Wiederholen mehr bzw. Abbruch/Sicherheit)
    v_report := v_class IN ('security', 'midway', 'interrupted', 'bot_down')
                OR (v_class IN ('unchanged', 'partial') AND NOT v_retry);

    v_text := core.fn_ui_text(v_head, v_lang, v_params);
    IF cardinality(v_todo) > 0 THEN
        v_text := v_text || E'\n\n' || core.fn_ui_text('core.update.todo.heading', v_lang) || E'\n'
                  || (SELECT string_agg(o || '. ' || core.fn_ui_text(k, v_lang, v_params), E'\n' ORDER BY o)
                        FROM unnest(v_todo) WITH ORDINALITY AS t(k, o));
    END IF;
    IF v_class NOT IN ('done', 'already_current', 'superseded') THEN
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
    IF v_help IS NOT NULL AND v_class NOT IN ('done', 'already_current', 'superseded') THEN
        v_urls := v_urls || jsonb_build_object('text', core.fn_ui_text('core.update.button.help', v_lang),
                                               'url', v_help || '#' || replace(v_class, '_', '-'));
    END IF;
    IF v_report AND v_slug IS NOT NULL THEN
        v_title := format('Update %s -> %s failed (%s / %s / %s)', COALESCE(v_r.from_version, '?'), v_r.tag,
                          v_class, COALESCE(v_r.stage, 'unknown'), COALESCE(v_r.reason_code, 'unknown'));
        v_body := format(E'From: %s\nTo: %s\nClass: %s\nStage: %s\nReason code: %s\n\nWhat did you do before the update?\n\n'
                         || E'<!-- Only attach log excerpts you have checked yourself: logs can contain your domain, names or IP addresses. -->',
                         COALESCE(v_r.from_version, '?'), v_r.tag, v_class,
                         COALESCE(v_r.stage, 'unknown'), COALESCE(v_r.reason_code, 'unknown'));
        v_urls := v_urls || jsonb_build_object('text', core.fn_ui_text('core.update.button.report', v_lang),
                    'url', 'https://github.com/' || v_slug || '/issues/new?title=' || core.fn_url_encode(v_title)
                           || '&body=' || core.fn_url_encode(v_body));
    END IF;
    IF jsonb_array_length(v_urls) > 0 THEN
        v_kb := v_kb || jsonb_build_array(v_urls);
    END IF;

    RETURN jsonb_build_object('text', v_text, 'keyboard', v_kb, 'class', v_class);
END;
$$;
