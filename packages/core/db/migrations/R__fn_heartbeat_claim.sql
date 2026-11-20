-- ============================================================
-- fn_heartbeat_claim (WRITE) — ein Lauf des Waechters ueber den Hintergrund-Teil
--   Aufrufer: core.cron_heartbeat_watch (Zeitplan schedule.heartbeat_watch, rund um die Uhr), einmal je Lauf in einer
--   MATERIALIZED CTE. Zaehlt je Signal die beobachtete Zeit seit dem letzten Beat und liefert die jetzt faelligen
--   Owner-Texte fertig in der Owner-Sprache. Tabellen und Zweck: packages/core/db/core.heartbeats_init.sql.
--   Beobachtete Zeit: Beitrag b = min(Luecke seit dem letzten Lauf, watch.step_cap_s); eine Luecke > watch.gap_s
--   (Rechner schlief, n8n stand), < 0 (Uhr zurueck) oder der erste Lauf ueberhaupt zaehlt 0. Je Signal
--   stale := min(stale + b, now - max(beat_at, busy_until)); solange busy_until in der Zukunft liegt 0.
--   Docker-Verbund (eine Schleife fuer alles): solange die Schleife faellig oder busy ist oder seit ihrem Alarm nicht
--   wieder schlug, zaehlen und melden Pruefung und Sicherung nicht (Ursache vor Folge). Klassisch (drei Timer) meldet
--   jedes Signal fuer sich.
--   Faellig (watch.*): loop ab loop_s; check ab check_s, bei Status not_release ab not_release_s Wanduhr seit
--   status_since (Text not_release); backup ab backup_s, still bei nofolder oder eigener Sicherungs-Meldung in
--   backup_notify_quiet_s.
--   Stufen: 1, dann nach repeat_first_s Stufe 2 („Erinnerung: …"), danach je repeat_s; eine neue Stufe 1 fruehestens
--   repeat_first_s nach der letzten Entwarnung. Entwarnung einmal, sobald ein alarmiertes Signal nach dem Alarm mit
--   gesundem Status schlug (nofolder zaehlt nicht). Rueckblick einmal, wenn die eigene Luecke watch.lookback_s
--   uebersteigt; eine weitere Luecke vor dem Senden behaelt den Beginn der ersten und nennt die laengste.
--   Nur an den gepaarten Owner, nur im Erinnerungs-Fenster (core.fn_in_reminder_window), nicht vor retry_after.
--   Config-Kreuzregeln (gap_s > step_cap_s, repeat_s >= repeat_first_s): Verstoss -> Standardwerte des Paars.
--   p: {at (nur Test: Zeitpunkt statt now())}
--   Rueckgabe: {messages:[{key, chat_id, text}]}; leer ohne Lebenszeichen, ungepaart, ausserhalb des Fensters, vor
--   retry_after oder wenn nichts faellig ist.
--   Seiteneffekte: seen_at, Rueckblick-Spalten, stale_observed_s und incident_at; je Nachricht reserviert
--   core.fn_should_notify den Merker (source 'heartbeat', Schluessel '<signal>:<incident_epoch>:<stufe|clear>' bzw.
--   'lookback:<epoch>') fuer 30 Minuten, endgueltig erst durch core.fn_heartbeat_finish; Merker aelter als 60 Tage
--   werden geloescht.
--   INVOKER: laeuft unter der Core-Host-Cred des Crons (Laufzeit-Grants auf agent/core).
--   Tests: tests/db/core/test_fn_heartbeat_claim.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_heartbeat_duration(p_secs numeric, p_mode text, p_lang text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
-- Dauer als Text fuer {dauer}: p_mode 'since' (abgerundet, „seit …") oder 'about' (gerundet, „etwa …").
-- Ein Key je Einheit und Zahl-Form (Einzahl hat eigene Grammatik: „seit einer Stunde", „etwa einen Tag").
DECLARE
    v_s    numeric := greatest(COALESCE(p_secs, 0), 0);
    v_n    bigint;
    v_unit text;
BEGIN
    IF p_mode = 'since' AND v_s < 3600 THEN
        v_n := greatest(1, floor(v_s / 60));
        v_unit := CASE WHEN v_n = 1 THEN 'minute' ELSE 'minutes' END;
    ELSIF (p_mode = 'since' AND v_s < 86400) OR (p_mode = 'about' AND v_s < 84600) THEN
        v_n := greatest(1, CASE WHEN p_mode = 'since' THEN floor(v_s / 3600) ELSE round(v_s / 3600) END);
        v_unit := CASE WHEN v_n = 1 THEN 'hour' ELSE 'hours' END;
    ELSE
        v_n := greatest(1, CASE WHEN p_mode = 'since' THEN floor(v_s / 86400) ELSE round(v_s / 86400) END);
        v_unit := CASE WHEN v_n = 1 THEN 'day' ELSE 'days' END;
    END IF;
    RETURN core.fn_ui_text(CASE p_mode || '.' || v_unit                 -- ausgeschrieben: locale_lint prueft jedes Key-Literal
               WHEN 'since.minute'  THEN 'core.heartbeat.since.minute'
               WHEN 'since.minutes' THEN 'core.heartbeat.since.minutes'
               WHEN 'since.hour'    THEN 'core.heartbeat.since.hour'
               WHEN 'since.hours'   THEN 'core.heartbeat.since.hours'
               WHEN 'since.day'     THEN 'core.heartbeat.since.day'
               WHEN 'since.days'    THEN 'core.heartbeat.since.days'
               WHEN 'about.hour'    THEN 'core.heartbeat.about.hour'
               WHEN 'about.hours'   THEN 'core.heartbeat.about.hours'
               WHEN 'about.day'     THEN 'core.heartbeat.about.day'
               ELSE                      'core.heartbeat.about.days' END,
           p_lang, jsonb_build_object('n', v_n));
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_heartbeat_claim(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_now     timestamptz := CASE WHEN pg_input_is_valid(p->>'at', 'timestamptz') THEN (p->>'at')::timestamptz ELSE now() END;
    v_def     constant jsonb := '{"loop_s":900,"check_s":43200,"not_release_s":3600,"backup_s":93600,"lookback_s":82800,
                                  "gap_s":1800,"step_cap_s":600,"repeat_first_s":86400,"repeat_s":604800,
                                  "backup_notify_quiet_s":72000}';
    v_cfg     jsonb := v_def;
    v_k       text;
    v_txt     text;
    v_obs     core.heartbeat_observer%ROWTYPE;
    v_delta   numeric;
    v_b       int;
    v_compose boolean;
    v_inhibit boolean;
    v_chat    bigint;
    v_lang    text;
    r         core.heartbeats%ROWTYPE;
    v_bad     text;
    v_want    int;
    v_key     text;
    v_msg     text;
    v_out     jsonb := '[]'::jsonb;
BEGIN
    -- Zeilensperre zuerst: zwei Laeufe (Doppel-Ausloesung, Hand-Start) zaehlen nie dieselbe Luecke doppelt
    SELECT * INTO v_obs FROM core.heartbeat_observer WHERE id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('messages', v_out);
    END IF;

    FOR v_k IN SELECT jsonb_object_keys(v_def) LOOP
        v_txt := core.fn_config_get('core', 'watch', v_k);
        IF v_txt ~ '^[0-9]{1,9}$' AND v_txt::int > 0 THEN
            v_cfg := jsonb_set(v_cfg, ARRAY[v_k], to_jsonb(v_txt::int));
        END IF;
    END LOOP;
    IF (v_cfg->>'gap_s')::int <= (v_cfg->>'step_cap_s')::int THEN
        v_cfg := v_cfg || jsonb_build_object('gap_s', v_def->'gap_s', 'step_cap_s', v_def->'step_cap_s');
    END IF;
    IF (v_cfg->>'repeat_s')::int < (v_cfg->>'repeat_first_s')::int THEN
        v_cfg := v_cfg || jsonb_build_object('repeat_s', v_def->'repeat_s', 'repeat_first_s', v_def->'repeat_first_s');
    END IF;

    v_delta := extract(epoch FROM v_now - v_obs.seen_at);
    v_b := CASE WHEN v_delta IS NULL OR v_delta < 0 OR v_delta > (v_cfg->>'gap_s')::int THEN 0
                ELSE least(v_delta, (v_cfg->>'step_cap_s')::int)::int END;
    UPDATE core.heartbeat_observer o
       SET seen_at        = v_now,
           -- noch offener Rueckblick: Beginn der ersten Luecke bleibt (Schluessel), die Dauer nennt die laengste
           lookback_from  = CASE WHEN v_delta > (v_cfg->>'lookback_s')::int THEN COALESCE(o.lookback_from, v_obs.seen_at)
                                 ELSE o.lookback_from END,
           lookback_gap_s = CASE WHEN v_delta > (v_cfg->>'lookback_s')::int
                                 THEN greatest(o.lookback_gap_s, least(v_delta, 2000000000)::int) ELSE o.lookback_gap_s END
     WHERE o.id
    RETURNING * INTO v_obs;
    v_compose := v_obs.runtime = 'compose';

    -- Zaehlen: direkte UPDATEs (ein paralleler Beat setzt stale auf 0 und gewinnt, kein Lesen-Aendern-Schreiben)
    UPDATE core.heartbeats h
       SET stale_observed_s = CASE WHEN h.busy_until > v_now THEN 0
                                   ELSE greatest(0, least(h.stale_observed_s + v_b,
                                            floor(extract(epoch FROM v_now - GREATEST(h.beat_at, h.busy_until)))))::int END
     WHERE h.signal = 'loop'
    RETURNING * INTO r;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('messages', v_out);
    END IF;
    -- alarmiert zaehlt nur bis zum ersten Beat danach: steht die Entwarnung noch aus (nachts, Sendefehler), zaehlen die
    -- Folgen schon wieder
    v_inhibit := v_compose AND (r.stale_observed_s >= (v_cfg->>'loop_s')::int OR r.busy_until > v_now
                                OR (r.alert_stage > 0 AND r.beat_at <= r.last_alert_at));
    UPDATE core.heartbeats h
       SET stale_observed_s = greatest(0, least(h.stale_observed_s + CASE WHEN v_inhibit THEN 0 ELSE v_b END,
                                  floor(extract(epoch FROM v_now - GREATEST(h.beat_at, h.busy_until)))))::int
     WHERE h.signal IN ('check', 'backup');

    PERFORM core.fn_notify_forget_before('heartbeat', now() - interval '60 days');

    IF v_obs.retry_after > v_now THEN
        RETURN jsonb_build_object('messages', v_out);
    END IF;
    v_chat := agent.fn_person_chat_id(agent.fn_owner_person_id());
    IF v_chat IS NULL OR NOT core.fn_in_reminder_window(v_now) THEN
        RETURN jsonb_build_object('messages', v_out);
    END IF;
    v_lang := agent.fn_person_lang(NULL)->>'lang';

    IF v_obs.lookback_from IS NOT NULL THEN
        v_key := 'lookback:' || floor(extract(epoch FROM v_obs.lookback_from))::bigint;
        IF core.fn_should_notify('heartbeat', v_key, interval '30 minutes') THEN
            v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'chat_id', v_chat,
                         'text', core.fn_ui_text('core.heartbeat.lookback', v_lang, jsonb_build_object(
                                 'dauer', core.fn_heartbeat_duration(v_obs.lookback_gap_s, 'about', v_lang)))));
        END IF;
    END IF;

    FOR r IN SELECT * FROM core.heartbeats ORDER BY array_position(ARRAY['loop', 'check', 'backup'], signal) LOOP
        CONTINUE WHEN r.signal <> 'loop' AND v_inhibit;
        -- v_bad = Text-Key der Lage (ausgeschrieben: locale_lint prueft jedes Key-Literal)
        v_bad := CASE
            WHEN r.signal = 'loop' AND r.stale_observed_s >= (v_cfg->>'loop_s')::int THEN
                 CASE WHEN v_compose THEN 'core.heartbeat.alert.loop.compose' ELSE 'core.heartbeat.alert.loop.systemd' END
            WHEN r.signal = 'check' AND r.status = 'not_release'
                 AND v_now - r.status_since >= make_interval(secs => (v_cfg->>'not_release_s')::int) THEN
                 'core.heartbeat.alert.not_release'
            WHEN r.signal = 'check' AND r.stale_observed_s >= (v_cfg->>'check_s')::int THEN
                 CASE WHEN v_compose THEN 'core.heartbeat.alert.check.compose' ELSE 'core.heartbeat.alert.check.systemd' END
            WHEN r.signal = 'backup' AND r.stale_observed_s >= (v_cfg->>'backup_s')::int AND r.status <> 'nofolder'
                 AND NOT COALESCE(r.notified_at > v_now - make_interval(secs => (v_cfg->>'backup_notify_quiet_s')::int), false) THEN
                 CASE WHEN v_compose THEN 'core.heartbeat.alert.backup.compose' ELSE 'core.heartbeat.alert.backup.systemd' END
        END;

        IF v_bad IS NOT NULL THEN
            IF r.alert_stage = 0 THEN
                -- Flattern: nach einer Entwarnung fruehestens repeat_first_s spaeter wieder Stufe 1
                CONTINUE WHEN r.last_clear_at > v_now - make_interval(secs => (v_cfg->>'repeat_first_s')::int);
                IF r.incident_at IS NULL THEN
                    UPDATE core.heartbeats SET incident_at = v_now WHERE signal = r.signal;
                    r.incident_at := v_now;
                END IF;
                v_want := 1;
            ELSIF v_now - r.last_alert_at >= make_interval(secs => CASE WHEN r.alert_stage = 1
                                                   THEN (v_cfg->>'repeat_first_s')::int ELSE (v_cfg->>'repeat_s')::int END) THEN
                v_want := r.alert_stage + 1;
            ELSE
                CONTINUE;
            END IF;
            v_key := r.signal || ':' || floor(extract(epoch FROM r.incident_at))::bigint || ':' || v_want;
            CONTINUE WHEN NOT core.fn_should_notify('heartbeat', v_key, interval '30 minutes');
            v_msg := core.fn_ui_text(v_bad, v_lang, jsonb_build_object(
                         'dauer', core.fn_heartbeat_duration(extract(epoch FROM v_now - GREATEST(r.beat_at, r.busy_until)),
                                                             'since', v_lang),
                         'help_url', COALESCE(v_obs.help_url, '')));
            IF v_want > 1 THEN
                v_msg := core.fn_ui_text('core.heartbeat.reminder', v_lang, jsonb_build_object('text', v_msg));
            END IF;
        ELSIF r.alert_stage > 0 AND r.beat_at > r.last_alert_at
              AND r.status IN ('ok', 'busy', 'skipped', 'current', 'attempted') THEN   -- nofolder sichert weiter nichts
            v_key := r.signal || ':' || floor(extract(epoch FROM r.incident_at))::bigint || ':clear';
            CONTINUE WHEN NOT core.fn_should_notify('heartbeat', v_key, interval '30 minutes');
            v_msg := core.fn_ui_text(CASE
                         WHEN r.signal = 'check'  THEN 'core.heartbeat.clear.check'
                         WHEN r.signal = 'backup' THEN 'core.heartbeat.clear.backup'
                         WHEN v_compose           THEN 'core.heartbeat.clear.loop.compose'
                         ELSE                          'core.heartbeat.clear.loop.systemd' END, v_lang);
        ELSE
            IF r.alert_stage = 0 AND r.incident_at IS NOT NULL THEN
                UPDATE core.heartbeats SET incident_at = NULL WHERE signal = r.signal;   -- nie gesendeter Vorfall
            END IF;
            CONTINUE;
        END IF;
        v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'chat_id', v_chat, 'text', v_msg));
    END LOOP;

    RETURN jsonb_build_object('messages', v_out);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_heartbeat_duration(numeric, text, text) FROM public;
REVOKE ALL ON FUNCTION core.fn_heartbeat_claim(jsonb) FROM public;
