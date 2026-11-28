-- ============================================================
-- core.fn_llm_incident_note (ATOMIC WRITE) — eine Pause der KI melden (Anbieter sperrt oder ist gestoert)
--   Aufrufer: Fehlerausgang des Orchestrator-Agenten (mit Update und Absender) und core.sub_error_notify (ohne), jeweils mit
--   dem festen Gateway-Code (classifyUpstreamError in provisioning/llm_gateway/server.js), gelesen aus der Fehlermeldung bzw.
--   dem Gateway-Zustand GET /__llm_status (Regel: Get-LlmPauseCodeJs in scripts/build/lib/build_helpers.ps1).
--   Art aus dem Code: spend_limit -> spend_limit, credit_empty -> credit_empty, auth -> auth, overloaded/upstream_error/
--   unreachable -> outage; rate_limited/other -> kein Vorfall (der Aufrufer sendet den normalen Hinweis und den Roh-Alarm).
--   Vorfall (core.llm_incidents, hoechstens einer offen): offener gleicher Art oder Stoerung waehrend einer Sperre -> der offene
--   (keine Herabstufung; resume_at wird nachgezogen); sonst neuer Vorfall, ein offener anderer wird 'superseded' und seine
--   gemerkten Nachrichten ziehen mit. Erste Nachschau nach 2 Min (Stoerung) bzw. 10 Min (core.fn_llm_probe_due).
--   Merken (agent.llm_held_messages): Text (kein Befehl), Datei (Foto/Dokument), Sprachnachricht; Dedupe ueber update_id,
--   hoechstens 10 je Absender (die aeltesten fallen raus).
--   Texte (Sprache: Empfaenger, agent.fn_person_lang; Datum/Uhrzeit in der Sitzungs-Zeitzone = Haushalt):
--     Owner-Karte einmal je Vorfall (nie bei Stoerung): Art-Text, Verbrauch im laufenden UTC-Monat (Anthropic rechnet in
--     UTC; core.v_llm_usage_cost, ganze USD, entfaellt unter 1), Datum laut Anbieter, gemerkte Nachricht; Knoepfe
--     spend_limit [Anleitung] (+ [Warten] mit Datum), credit_empty [Anleitung], auth keine. Schreibt der Owner selbst, ist
--     die Karte die Antwort (reply_*), sonst owner_card (Empfaenger = Owner, sendet der Workflow).
--     Owner erneut: Kurzsatz; Mitglied: eigener Text ohne Betrag und Knoepfe; Stoerung: ein Satz an den Schreiber.
--   Eingabe p: { code (Pflicht), resume_at? (ISO-UTC 'YYYY-MM-DDTHH:MI:SSZ'), source? ('orchestrator'|'error_notify', nur Lesbarkeit des Aufrufs, nicht ausgewertet),
--     chat_id? (Telegram-Absender), update? (Telegram-Update mit message) }
--   Rueckgabe: kein Vorfall (rate_limited/other) -> {ok:true, kind:null, suppress_alert:false, held:false};
--     sonst {ok:true, kind, incident_id, reply_text?, reply_buttons ([[{text,data}]]), owner_card?:{text, buttons},
--     suppress_alert (true = sortierter Fall, kein Roh-Alarm), held, messages:[{chat_id, text, buttons}] (dieselben Texte
--     mit Empfaenger fuer core.sub_send_messages)} | {ok:false, reason:'unknown_code'}
--   Tests: tests/db/core/test_fn_llm_incident_note.sql
-- ============================================================

-- Art eines Gateway-Codes (NULL = kein Vorfall); unbekannter Code -> 'unknown'.
CREATE OR REPLACE FUNCTION core.fn_llm_kind(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_code
        WHEN 'spend_limit' THEN 'spend_limit' WHEN 'credit_empty' THEN 'credit_empty' WHEN 'auth' THEN 'auth'
        WHEN 'overloaded' THEN 'outage' WHEN 'upstream_error' THEN 'outage' WHEN 'unreachable' THEN 'outage'
        WHEN 'rate_limited' THEN NULL WHEN 'other' THEN NULL
        ELSE 'unknown' END;
$$;

-- Zeitpunkt fuer {when}: heute nur Uhrzeit, sonst Datum (Sprache) + Uhrzeit; Sitzungs-Zeitzone.
CREATE OR REPLACE FUNCTION core.fn_llm_when(p_ts timestamptz, p_lang text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_ts::date = current_date THEN to_char(p_ts, 'HH24:MI')
                ELSE core.fn_fmt_date(p_ts::date, p_lang) || ' ' || to_char(p_ts, 'HH24:MI') END;
$$;

-- Owner-Karte eines Vorfalls: {text, buttons}. p_when = Zeitpunkt der gemerkten Nachricht des Owners (NULL = keine Zeile).
CREATE OR REPLACE FUNCTION core.fn_llm_owner_card(p_inc core.llm_incidents, p_lang text, p_when text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_parts text[];
    v_usd   numeric;
    v_btn   jsonb := '[]'::jsonb;
BEGIN
    v_parts := ARRAY[core.fn_ui_text(CASE p_inc.kind WHEN 'spend_limit' THEN 'core.llm_pause.owner_spend_limit'
                                                     WHEN 'credit_empty' THEN 'core.llm_pause.owner_credit_empty'
                                                     ELSE 'core.llm_pause.owner_auth' END, p_lang)];
    IF p_inc.kind IN ('spend_limit', 'credit_empty') THEN
        SELECT sum(v.usd) INTO v_usd FROM core.v_llm_usage_cost v
         WHERE NOT v.unpriced AND v.ts >= date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
        IF v_usd >= 1 THEN
            v_parts := v_parts || core.fn_ui_text('core.llm_pause.spent_line', p_lang, jsonb_build_object('usd', core.fn_ui_num(round(v_usd))));
        END IF;
    END IF;
    IF p_inc.kind = 'spend_limit' AND p_inc.resume_at IS NOT NULL THEN
        v_parts := v_parts || core.fn_ui_text('core.llm_pause.resume_line', p_lang,
            jsonb_build_object('date', core.fn_ui_date(p_inc.resume_at::date), 'time', to_char(p_inc.resume_at, 'HH24:MI')));
    ELSIF p_inc.kind = 'credit_empty' THEN
        v_parts := v_parts || core.fn_ui_text('core.llm_pause.credit_line', p_lang);
    END IF;
    IF p_when IS NOT NULL THEN
        v_parts := v_parts || core.fn_ui_text('core.llm_pause.held_line', p_lang, jsonb_build_object('when', p_when));
    END IF;
    IF p_inc.kind = 'spend_limit' THEN
        v_btn := jsonb_build_array(jsonb_build_array(jsonb_build_object(
            'text', core.fn_ui_text('core.llm_pause.btn_raise', p_lang), 'data', 'llm:guide:' || p_inc.id)));
        IF p_inc.resume_at IS NOT NULL THEN
            v_btn := v_btn || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'text', core.fn_ui_text('core.llm_pause.btn_wait', p_lang, jsonb_build_object('date', core.fn_ui_date(p_inc.resume_at::date))),
                'data', 'llm:wait:' || p_inc.id)));
        END IF;
    ELSIF p_inc.kind = 'credit_empty' THEN
        v_btn := jsonb_build_array(jsonb_build_array(jsonb_build_object(
            'text', core.fn_ui_text('core.llm_pause.btn_topup', p_lang), 'data', 'llm:guide:' || p_inc.id)));
    END IF;
    RETURN jsonb_build_object('text', array_to_string(v_parts, E'\n\n'), 'buttons', v_btn);
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_llm_incident_note(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_code   text := p->>'code';
    v_kind   text := core.fn_llm_kind(p->>'code');
    v_resume timestamptz;
    v_inc    core.llm_incidents%ROWTYPE;
    v_old    core.llm_incidents%ROWTYPE;
    v_chat   bigint;
    v_sender jsonb;
    v_role   text;
    v_lang   text;
    v_upd    jsonb := p->'update';
    v_m      jsonb := p->'update'->'message';
    v_hkind  text;
    v_sent   timestamptz;
    v_when   text;
    v_held   boolean := false;
    v_first  boolean;
    v_parts  text[];
    v_reply  text;
    v_btn    jsonb := '[]'::jsonb;
    v_card   jsonb;
BEGIN
    IF v_kind = 'unknown' OR v_code IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_code');
    END IF;
    IF v_kind IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'kind', NULL, 'suppress_alert', false, 'held', false);
    END IF;
    IF v_kind = 'spend_limit' AND COALESCE(p->>'resume_at', '') ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' THEN
        v_resume := (p->>'resume_at')::timestamptz;
    END IF;

    -- Ein Vorfall zur Zeit: parallele Fehlerlaeufe nacheinander (der Unique-Index ist das Gesetz, der Lock vermeidet den Fehler).
    PERFORM pg_advisory_xact_lock(hashtext('core.llm_incidents'));
    SELECT * INTO v_old FROM core.llm_incidents WHERE closed_at IS NULL FOR UPDATE;
    IF FOUND AND (v_old.kind = v_kind OR v_kind = 'outage') THEN
        v_inc := v_old;
        IF v_inc.kind = 'spend_limit' AND v_resume IS NOT NULL AND v_inc.resume_at IS DISTINCT FROM v_resume THEN
            UPDATE core.llm_incidents SET resume_at = v_resume WHERE id = v_inc.id RETURNING * INTO v_inc;
        END IF;
    ELSE
        IF v_old.id IS NOT NULL THEN
            UPDATE core.llm_incidents SET closed_at = now(), close_reason = 'superseded', probe_lock_until = NULL WHERE id = v_old.id;
        END IF;
        INSERT INTO core.llm_incidents (kind, resume_at, next_probe_at)
        VALUES (v_kind, v_resume, now() + CASE WHEN v_kind = 'outage' THEN interval '2 minutes' ELSE interval '10 minutes' END)
        RETURNING * INTO v_inc;
        IF v_old.id IS NOT NULL THEN
            UPDATE agent.llm_held_messages SET incident_id = v_inc.id WHERE incident_id = v_old.id;
        END IF;
    END IF;

    -- Absender und Sprache (ohne Absender: Owner-Sprache)
    IF COALESCE(p->>'chat_id', '') ~ '^-?[0-9]{1,18}$' THEN
        v_chat := (p->>'chat_id')::bigint;
        v_sender := agent.fn_resolve_sender(v_chat);
        IF COALESCE((v_sender->>'found')::boolean, false) THEN v_role := v_sender->>'role'; END IF;
    END IF;
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';

    -- Nachricht merken
    IF jsonb_typeof(v_m) = 'object' AND COALESCE(v_upd->>'update_id', '') ~ '^[0-9]{1,18}$'
       AND COALESCE(v_m->'chat'->>'id', '') ~ '^-?[0-9]{1,18}$' AND COALESCE(v_m->>'message_id', '') ~ '^[0-9]{1,18}$' THEN
        v_hkind := CASE
            WHEN jsonb_typeof(v_m->'photo') = 'array' OR jsonb_typeof(v_m->'document') = 'object' THEN 'file'
            WHEN jsonb_typeof(v_m->'voice') = 'object' THEN 'voice'
            WHEN jsonb_typeof(v_m->'text') = 'string' AND (v_m->>'text') !~ '^\s*/' THEN 'text' END;
        IF v_hkind IS NOT NULL THEN
            v_sent := CASE WHEN COALESCE(v_m->>'date', '') ~ '^[0-9]{1,12}$' THEN to_timestamp((v_m->>'date')::bigint) ELSE now() END;
            INSERT INTO agent.llm_held_messages (update_id, incident_id, chat_id, from_id, message_id, kind, payload, sent_at)
            VALUES ((v_upd->>'update_id')::bigint, v_inc.id, (v_m->'chat'->>'id')::bigint,
                    COALESCE(NULLIF(v_m->'from'->>'id', '')::bigint, (v_m->'chat'->>'id')::bigint),
                    (v_m->>'message_id')::bigint, v_hkind, v_upd, v_sent)
            ON CONFLICT (update_id) DO NOTHING;
            DELETE FROM agent.llm_held_messages WHERE update_id IN (
                SELECT h.update_id FROM agent.llm_held_messages h
                 WHERE h.chat_id = (v_m->'chat'->>'id')::bigint
                   AND h.from_id = COALESCE(NULLIF(v_m->'from'->>'id', '')::bigint, (v_m->'chat'->>'id')::bigint)
                 ORDER BY h.message_id DESC, h.update_id DESC OFFSET 10);
            v_held := EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE update_id = (v_upd->>'update_id')::bigint);
            IF v_held THEN v_when := core.fn_llm_when(v_sent, v_lang); END IF;
        END IF;
    END IF;

    -- Texte
    v_first := v_inc.kind <> 'outage' AND v_inc.owner_notified_at IS NULL;
    IF v_inc.kind = 'outage' THEN
        IF v_chat IS NOT NULL THEN
            v_parts := ARRAY[core.fn_ui_text('core.llm_pause.outage', v_lang)];
            IF v_held THEN v_parts := v_parts || core.fn_ui_text('core.llm_pause.outage_held', v_lang); END IF;
        END IF;
    ELSIF v_role = 'owner' THEN
        IF v_first THEN
            v_card := core.fn_llm_owner_card(v_inc, v_lang, v_when);
            v_reply := v_card->>'text';
            v_btn := v_card->'buttons';
            v_card := NULL;
        ELSE
            -- Keys ausgeschrieben: locale_lint prueft jedes Key-Literal
            v_parts := ARRAY[core.fn_ui_text(CASE v_inc.kind WHEN 'spend_limit' THEN 'core.llm_pause.owner_again_spend_limit'
                                                             WHEN 'credit_empty' THEN 'core.llm_pause.owner_again_credit_empty'
                                                             ELSE 'core.llm_pause.owner_again_auth' END, v_lang)];
            IF v_inc.resume_at IS NOT NULL THEN
                v_parts := v_parts || core.fn_ui_text('core.llm_pause.resume_line', v_lang,
                    jsonb_build_object('date', core.fn_ui_date(v_inc.resume_at::date), 'time', to_char(v_inc.resume_at, 'HH24:MI')));
            END IF;
            IF v_held THEN v_parts := v_parts || core.fn_ui_text('core.llm_pause.held_line', v_lang, jsonb_build_object('when', v_when)); END IF;
        END IF;
    ELSE
        IF v_role IS NOT NULL THEN
            v_parts := ARRAY[core.fn_ui_text(CASE v_inc.kind WHEN 'spend_limit' THEN 'core.llm_pause.member_spend_limit'
                                                             WHEN 'credit_empty' THEN 'core.llm_pause.member_credit_empty'
                                                             ELSE 'core.llm_pause.member_auth' END, v_lang)];
            IF v_inc.resume_at IS NOT NULL THEN
                v_parts := v_parts || core.fn_ui_text('core.llm_pause.member_resume_line', v_lang,
                    jsonb_build_object('date', core.fn_ui_date(v_inc.resume_at::date), 'time', to_char(v_inc.resume_at, 'HH24:MI')));
            END IF;
            IF v_held THEN v_parts := v_parts || core.fn_ui_text('core.llm_pause.member_held', v_lang); END IF;
        END IF;
        IF v_first THEN
            v_card := core.fn_llm_owner_card(v_inc, agent.fn_person_lang(NULL)->>'lang', NULL);
        END IF;
    END IF;
    IF v_parts IS NOT NULL THEN v_reply := array_to_string(v_parts, E'\n\n'); END IF;
    IF v_first THEN
        UPDATE core.llm_incidents SET owner_notified_at = now() WHERE id = v_inc.id;
    END IF;

    RETURN jsonb_build_object('ok', true, 'kind', v_inc.kind, 'incident_id', v_inc.id, 'reply_text', v_reply,
        'reply_buttons', COALESCE(v_btn, '[]'::jsonb), 'owner_card', v_card, 'suppress_alert', true, 'held', v_held,
        -- dieselben Texte als Sendeliste fuer core.sub_send_messages (Antwort an den Schreiber, Karte an den Owner)
        'messages', (SELECT COALESCE(jsonb_agg(m), '[]'::jsonb) FROM (
            SELECT jsonb_build_object('chat_id', v_chat::text, 'text', v_reply, 'buttons', COALESCE(v_btn, '[]'::jsonb)) AS m
             WHERE v_reply IS NOT NULL AND v_chat IS NOT NULL
            UNION ALL
            SELECT jsonb_build_object('chat_id', o::text, 'text', v_card->>'text', 'buttons', v_card->'buttons')
              FROM agent.fn_person_chat_id(agent.fn_owner_person_id()) o
             WHERE v_card IS NOT NULL AND o IS NOT NULL) x));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_llm_incident_note(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_llm_incident_note(JSONB) FROM context_ro;
    END IF;
END $$;
