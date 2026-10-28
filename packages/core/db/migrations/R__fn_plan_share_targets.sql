-- ============================================================
-- core.fn_plan_share_targets(p) — Versand-Liste "Erwachsene informieren" (Plan teilen, 2026-10-28)
--   Gerufen vom Sub core.sub_share_plan nach dem Owner-Tipp plan:share:<domain>:<version>. Prueft (auch wenn der
--   Handler schon prueft — alte Karten, Doppel-Tipp): Absender = Owner, p.version = aktive Version des Haushalts-Plans
--   (core.fn_household_plan_active, sonst reason 'stale'). Empfaenger = core.fn_plan_adult_recipients (Rolle partner,
--   Chat, plan_news erlaubt — darin auch der Notschalter cron_enable.plan_news).
--   READ-ONLY: wer fuer DIESEN Plan schon informiert wurde (Merker core.notification_state source 'plan_news', key
--   '<pid>:<domain>:p<plan_id>' im Zustand fired), zaehlt zu already; alle anderen kommen in targets. Den Merker setzt erst
--   core.fn_plan_share_mark NACH einem zugestellten Send (Code-Review 2026-10-28: ein vorab gesetzter Merker verschluckte
--   Personen, wenn der Lauf zwischen Liste und Send starb). Key an der plan_id (nicht der Version): ein Daten-Reset
--   beginnt wieder bei Version 1, die plan_id (serial) nie — sonst galten alle als "schon informiert".
--   show_summary = die Sprache der Person ist die Sprache der gespeicherten Zusammenfassung (change_summary_lang) — der
--   Text wird nie uebersetzt; sonst erklaert der Berater die Aenderungen in ihrer Sprache. summary auf 1500 Zeichen gekappt.
--   p: { domain, version, chat_id (Tapper, build-fix aus dem Callback, nie LLM) }
--   RUECKGABE: {ok:true, plan_id, version, package, summary, targets:[{person_id, chat_id, lang, show_summary}], already, none}
--            | {ok:false, reason: owner_only|stale|unknown_plan}. Nie RAISE.
--   STABLE, SECURITY DEFINER, search_path gepinnt; EXECUTE nur die Host-Cred (REVOKE PUBLIC).
--   Tests: tests/db/core/test_fn_plan_share_targets.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_share_targets(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain  text := COALESCE(p->>'domain', '');
    v_chat    text := COALESCE(p->>'chat_id', '');
    v_version int;
    v_plan    record;
    v_targets jsonb := '[]'::jsonb;
    v_already int := 0;
    r         record;
BEGIN
    BEGIN
        v_version := NULLIF(p->>'version', '')::int;
    EXCEPTION WHEN OTHERS THEN
        v_version := NULL;
    END;
    IF v_chat !~ '^[0-9]{1,18}$' OR (agent.fn_resolve_sender(v_chat::bigint)->>'role') IS DISTINCT FROM 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;
    SELECT * INTO v_plan FROM core.fn_household_plan_active(v_domain);
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_plan');
    END IF;
    IF v_version IS DISTINCT FROM v_plan.version THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'stale');
    END IF;

    FOR r IN SELECT * FROM core.fn_plan_adult_recipients(v_domain) LOOP
        IF EXISTS (SELECT 1 FROM core.notification_state ns
                    WHERE ns.source = 'plan_news' AND ns.state = 'fired'
                      AND ns.key = r.person_id || ':' || v_domain || ':p' || v_plan.plan_id) THEN
            v_already := v_already + 1;
        ELSE
            v_targets := v_targets || jsonb_build_array(jsonb_build_object(
                'person_id', r.person_id, 'chat_id', r.chat_id, 'lang', r.lang,
                'show_summary', v_plan.change_summary IS NOT NULL AND r.lang IS NOT DISTINCT FROM v_plan.change_summary_lang));
        END IF;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'plan_id', v_plan.plan_id, 'version', v_plan.version, 'package', v_plan.package,
        'summary', left(COALESCE(v_plan.change_summary, ''), 1500),
        'targets', v_targets, 'already', v_already,
        'none', jsonb_array_length(v_targets) = 0 AND v_already = 0);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_plan_share_targets(jsonb) FROM public;
