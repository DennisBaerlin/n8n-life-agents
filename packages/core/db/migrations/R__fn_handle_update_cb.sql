-- ============================================================
-- core.fn_handle_update_cb(p) — Registry-Handler des Callback-Prefix 'upd' (owner-only; Update-Hinweis 2026-10-24)
--   callback_data 'upd:now|retry:<tag>' von der Release-Karte ([Jetzt aktualisieren], core.fn_release_card) bzw.
--   der Fehler-Hilfe ([Erneut versuchen], core.fn_update_report). Legt EINEN Auftrag in core.update_requests an;
--   ausgefuehrt wird er vom root-Runner (systemd-Timer, `lifeagents update --run-requested`), der Tag, VERSION und
--   releases/latest selbst noch einmal prueft (diese fn ist Komfort, nie die Sicherheitsgrenze fuer root).
--   Erreicht ueber core.fn_dispatch_callback (Member-Gate: member_permeable=false -> nur der Owner); der Handler
--   prueft die Owner-Rolle zusaetzlich selbst (direkter Aufruf, Defense-in-Depth).
--     * now   -> nur fuer ein Tag, dessen Karte wirklich ging (Latch release_update/<tag>, core.fn_release_card_sent);
--     * retry -> nur, wenn core.fn_update_retry_allowed(<tag>) (die eine Wiederholungs-Regel);
--     * schon ein offener Auftrag -> Toast "laeuft schon" (Unique-Index ist das Gesetz, hier nur freundlich).
--   p: { data, chat_id (from.id), chat_type }
--   RUECKGABE: {ok:true, toast, request_id} | {ok:false, reason:'owner_only'|'invalid'|'unknown_release'|
--              'already_open'|'no_retry', toast}. Toasts in der Sprache des Tippenden (core.update.toast.*). Nie RAISE.
--   SECURITY INVOKER (Host-Cred des Dispatchers, die core.* schreibt), search_path gepinnt.
--   Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_update_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_verb   text := split_part(v_data, ':', 2);
    v_tag    text := split_part(v_data, ':', 3);
    v_chat   bigint;
    v_sender jsonb;
    v_lang   text;
    v_id     bigint;
BEGIN
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := agent.fn_resolve_sender(v_chat);
    v_lang   := agent.fn_person_lang(v_sender->>'person_id')->>'lang';

    IF NOT COALESCE((v_sender->>'found')::boolean, false) OR (v_sender->>'role') IS DISTINCT FROM 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only',
            'toast', core.fn_ui_text('core.toast.owner_only', v_lang));
    END IF;
    IF v_verb NOT IN ('now', 'retry') OR split_part(v_data, ':', 4) <> ''
       OR core.fn_semver_cmp(v_tag, v_tag) IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid',
            'toast', core.fn_ui_text('core.update.toast.invalid', v_lang));
    END IF;
    IF EXISTS (SELECT 1 FROM core.update_requests WHERE finished_at IS NULL) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'already_open',
            'toast', core.fn_ui_text('core.update.toast.running', v_lang));
    END IF;
    IF v_verb = 'now' AND NOT EXISTS (
           SELECT 1 FROM core.notification_state n
            WHERE n.source = 'release_update' AND n.key = v_tag AND n.state = 'fired') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_release',
            'toast', core.fn_ui_text('core.update.toast.invalid', v_lang));
    END IF;
    IF v_verb = 'retry' AND NOT core.fn_update_retry_allowed(v_tag) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'no_retry',
            'toast', core.fn_ui_text('core.update.toast.no_retry', v_lang));
    END IF;

    BEGIN
        INSERT INTO core.update_requests (kind, tag, requested_by)
        VALUES (CASE v_verb WHEN 'now' THEN 'update' ELSE 'retry' END, v_tag, v_sender->>'person_id')
        RETURNING id INTO v_id;
    EXCEPTION
        WHEN unique_violation THEN   -- paralleler Tap zwischen EXISTS und INSERT
            RETURN jsonb_build_object('ok', false, 'reason', 'already_open',
                'toast', core.fn_ui_text('core.update.toast.running', v_lang));
        WHEN check_violation THEN    -- Backstop: der CHECK ist das Gesetz (Tag-Form), der Handler raised trotzdem nie
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid',
                'toast', core.fn_ui_text('core.update.toast.invalid', v_lang));
    END;
    RETURN jsonb_build_object('ok', true, 'request_id', v_id,
        'toast', core.fn_ui_text('core.update.toast.started', v_lang));
END;
$$;
