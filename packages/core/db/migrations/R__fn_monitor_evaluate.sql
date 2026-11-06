-- ============================================================
-- fn_monitor_evaluate (ATOMIC WRITE — die EINE Auswertung des Heartbeat-Crons)
--   Wertet alle faelligen, scharfen Trigger DETERMINISTISCH aus (das LLM beschafft
--   hoechstens Werte, entscheidet nie). Eine Transaktion; RAISE -> Auto-Rollback.
--   Ablauf je Trigger (FOR UPDATE — Cron parallel zu set-Tool = zwei n8n-Executions):
--     1. Due-Set wird HIER unter Lock neu berechnet (TOCTOU-Guard: ein zwischenzeitlich
--        disabled/editierter Trigger wird mit Row-Wahrheit ausgewertet; die Workflow-
--        Observation liefert nur value/unit/as_of/source)
--     1b. PARKEN (Phase B): Trigger einer Paket-Methode, die gerade nicht verfuegbar ist (Paket deinstalliert/
--        inaktiv, Platzhalter ohne acquire_fn — fn_monitor_method_status), werden NICHT ausgewertet: kein
--        fail_streak, kein Problem-Alarm, next_check_at unberuehrt -> sie laufen von selbst wieder an, sobald
--        das Paket aktiv ist (deckt `--keep-data`-Deinstall + deaktivierte Pakete; Spiegel in fn_monitor_due).
--     2. Beschaffung: web_search aus p.observations (Workflow); sql/none/Paket-Methoden via
--        fn_monitor_acquire (sql unter SET LOCAL ROLE core_ro; Paket-Methoden ueber ihre acquire_fn)
--     3. Validierungs-Kaskade fn_validate_observation (numerisch/Unit-Echo/Bounds/Jump)
--     4. Observation-Log IMMER (agent.monitor_observations — Audit auch fuer dirty)
--     5. dirty -> fail_streak++; Problem-Alarm exakt beim Erreichen von
--        monitor.fail_alert_streak und jedem Vielfachen (taucht wieder auf, nervt aber
--        nicht jede Runde); last_value/Ratchet/Fire UNBERUEHRT (Peak-Poisoning-Schutz)
--     6. clean -> last_value/-as_of, fail_streak=0, dann je Typ:
--        threshold: gte/lte-Vergleich -> One-Shot-Latch (armed->fired)
--        drawdown:  reference_value = GREATEST(ref, value) (Ratchet, nur saubere Werte);
--                   dd% = (ref-value)/ref*100 >= drawdown_pct -> Latch
--        date:      heute >= due_date -> Latch; im Warn-Fenster (due - warn_days_before)
--                   VORHER: NICHT-latchende date_warning-Info (Reviewer-Blocker-Fix:
--                   die Deadline selbst darf nie still verstreichen)
--        recurring_info: Info-Eintrag jede faellige Runde, latcht NIE
--     7. next_check_at via fn_next_check IMMER advancen (Erfolg UND Fehlschlag — sonst
--        brennt ein kaputter Web-Prompt jede Heartbeat-Runde einen Web-Abruf)
--   Datums-Logik gepinnt: heute = core.fn_today(now) (Haushalts-Zeitzone der Sitzung, die eine Adresse fuer "heute").
--   ERINNERUNGS-FENSTER (Roter Faden, Owner-Entscheid 2026-10-23, core.fn_in_reminder_window): Wert-Waechter
--   (threshold/drawdown) melden sofort, auch nachts. Datums-/Info-Trigger gelten ausserhalb des Fensters nicht als
--   faellig (bleiben faellig -> erster Lauf im Fenster). Ein Problembericht ausserhalb des Fensters wird vorgemerkt
--   (monitor_triggers.problem_pending_at) und im ersten Lauf im Fenster nachgereicht, solange der Trigger noch scheitert.
--   Eingabe jsonb: { now? (Test-Injektion), observations?: [{trigger_id, ok, value,
--     unit, as_of, source_url, reason}], fail_alert_streak? (Override; Default RUNTIME aus
--     core.config monitor.fail_alert_streak — bewusst kein Build-Time-Baking) }.
--   Rueckgabe: { ok, checked, fired:[...], info:[...], problems:[...] } — alles, was
--   der deterministische Message-Builder braucht, nichts mehr (Post-State-Vertrag).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_evaluate(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_now        TIMESTAMPTZ := COALESCE(NULLIF(p->>'now', '')::timestamptz, NOW());
    v_today      DATE;
    v_fail_alert INT;
    v_checked    INT := 0;
    v_fired      JSONB := '[]'::jsonb;
    v_info       JSONB := '[]'::jsonb;
    v_problems   JSONB := '[]'::jsonb;
    v_t          agent.monitor_triggers%ROWTYPE;
    v_obs        JSONB;
    v_ok         BOOLEAN;
    v_value      NUMERIC;
    v_fire       BOOLEAN;
    v_ref        NUMERIC;
    v_dd         NUMERIC;
    v_streak     INT;
    v_first_fail TIMESTAMPTZ;
    v_window     BOOLEAN;
BEGIN
    v_today := core.fn_today(v_now);
    v_fail_alert := COALESCE(NULLIF(p->>'fail_alert_streak', '')::int,
        (SELECT c.value::int FROM core.config c
          WHERE c.category = 'monitor' AND c.key = 'fail_alert_streak'), 3);

    v_window := core.fn_in_reminder_window(v_now);

    FOR v_t IN
        SELECT * FROM agent.monitor_triggers t
        WHERE t.status = 'armed' AND t.next_check_at <= v_now
          AND COALESCE((agent.fn_monitor_method_status(t.acquisition_method)->>'available')::boolean, false)
          -- Roter Faden: Datums-/Info-Trigger (nicht zeitkritisch) nur im Erinnerungs-Fenster; sie bleiben faellig
          -- und laufen im ersten Lauf ab reminders_from (Spiegel in agent.fn_monitor_due).
          AND (t.trigger_type NOT IN ('date', 'recurring_info') OR v_window)
        ORDER BY t.id
        FOR UPDATE
    LOOP
        v_checked := v_checked + 1;

        -- 2. Beschaffung
        IF v_t.acquisition_method = 'web_search' THEN
            SELECT x.o INTO v_obs
            FROM jsonb_array_elements(COALESCE(p->'observations', '[]'::jsonb)) AS x(o)
            WHERE (x.o->>'trigger_id')::int = v_t.id
            LIMIT 1;
            IF v_obs IS NULL THEN
                v_obs := jsonb_build_object('ok', false,
                    'reason', 'no observation delivered by workflow');
            END IF;
        ELSE
            v_obs := agent.fn_monitor_acquire(
                v_t.acquisition_method, v_t.acquisition_spec, v_today);
        END IF;

        -- 3. Validierungs-Kaskade
        v_obs := agent.fn_validate_observation(
            v_obs, v_t.acquisition_method, v_t.expected_unit,
            v_t.min_plausible, v_t.max_plausible, v_t.max_jump_pct, v_t.last_value);
        v_ok := (v_obs->>'ok')::boolean;
        v_value := (v_obs->>'value')::numeric;  -- validate liefert value nur wenn numerisch

        -- 4. Observation-Log (immer; Audit-Spur auch fuer dirty)
        INSERT INTO agent.monitor_observations
            (trigger_id, ok, value, unit, as_of, source_url, reason, fetched_at)
        VALUES (v_t.id, v_ok, v_value, v_obs->>'unit', v_obs->>'as_of',
                v_obs->>'source_url', v_obs->>'reason', v_now);

        -- 5. dirty -> Fehlerpfad (State unberuehrt ausser Streak + Advance)
        IF NOT v_ok THEN
            UPDATE agent.monitor_triggers
               SET fail_streak     = fail_streak + 1,
                   last_checked_at = v_now,
                   next_check_at   = agent.fn_next_check(next_check_at, check_interval, v_now)
             WHERE id = v_t.id
             RETURNING fail_streak INTO v_streak;

            -- Roter Faden: ein Problembericht ausserhalb des Erinnerungs-Fensters wird vorgemerkt (problem_pending_at)
            -- und im ersten Lauf im Fenster nachgereicht (unten) — nie verworfen, nie nachts gesendet.
            IF v_streak % v_fail_alert = 0 AND NOT v_window THEN
                UPDATE agent.monitor_triggers SET problem_pending_at = v_now WHERE id = v_t.id;
            ELSIF v_streak % v_fail_alert = 0 THEN
                SELECT MIN(s.fetched_at) INTO v_first_fail FROM (
                    SELECT o.fetched_at FROM agent.monitor_observations o
                    WHERE o.trigger_id = v_t.id
                    ORDER BY o.fetched_at DESC, o.id DESC
                    LIMIT v_streak
                ) s;
                v_problems := v_problems || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                    'id', v_t.id, 'label', v_t.label, 'domain', v_t.domain,
                    'fail_streak', v_streak, 'reason', v_obs->>'reason',
                    'first_fail', to_char(v_first_fail, 'DD.MM.YYYY'))));
            END IF;
            CONTINUE;
        END IF;

        -- 6. clean -> Typ-Logik
        v_fire := false;
        v_ref  := v_t.reference_value;
        v_dd   := NULL;

        IF v_t.trigger_type = 'date' THEN
            IF v_today >= v_t.due_date THEN
                v_fire := true;
            ELSIF v_t.warn_days_before > 0
                  AND v_today >= v_t.due_date - v_t.warn_days_before THEN
                v_info := v_info || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                    'id', v_t.id, 'label', v_t.label, 'domain', v_t.domain,
                    'kind', 'date_warning',
                    'due_date', v_t.due_date::text,
                    'days_left', (v_t.due_date - v_today),
                    'action_note', v_t.action_note)));
            END IF;
        ELSIF v_t.trigger_type = 'threshold' THEN
            v_fire := (v_t.comparator = 'gte' AND v_value >= v_t.threshold_value)
                   OR (v_t.comparator = 'lte' AND v_value <= v_t.threshold_value);
        ELSIF v_t.trigger_type = 'drawdown' THEN
            v_ref := GREATEST(COALESCE(v_t.reference_value, v_value), v_value);
            IF v_ref > 0 THEN
                v_dd := round((v_ref - v_value) / v_ref * 100, 2);
                v_fire := v_dd >= v_t.drawdown_pct;
            END IF;
        ELSIF v_t.trigger_type = 'recurring_info' THEN
            v_info := v_info || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'id', v_t.id, 'label', v_t.label, 'domain', v_t.domain,
                'kind', 'recurring_info',
                'value', v_value,
                'unit', COALESCE(v_obs->>'unit', v_t.expected_unit),
                'as_of', v_obs->>'as_of',
                'action_note', v_t.action_note)));
        END IF;

        UPDATE agent.monitor_triggers
           SET last_checked_at  = v_now,
               next_check_at    = agent.fn_next_check(next_check_at, check_interval, v_now),
               fail_streak      = 0,
               last_value       = COALESCE(v_value, last_value),
               last_value_as_of = CASE WHEN v_value IS NOT NULL
                                       THEN COALESCE(v_obs->>'as_of', v_today::text)
                                       ELSE last_value_as_of END,
               reference_value  = CASE WHEN v_t.trigger_type = 'drawdown'
                                       THEN v_ref ELSE reference_value END,
               status           = CASE WHEN v_fire THEN 'fired' ELSE status END,
               fired_at         = CASE WHEN v_fire THEN v_now ELSE fired_at END
         WHERE id = v_t.id;

        IF v_fire THEN
            v_fired := v_fired || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'id', v_t.id, 'label', v_t.label, 'domain', v_t.domain,
                'trigger_type', v_t.trigger_type,
                'value', v_value,
                'unit', COALESCE(v_obs->>'unit', v_t.expected_unit),
                'as_of', v_obs->>'as_of',
                'source_url', v_obs->>'source_url',
                'comparator', v_t.comparator,
                'threshold_value', v_t.threshold_value,
                'drawdown_pct', v_t.drawdown_pct,
                'drawdown_observed', v_dd,
                'reference_value', CASE WHEN v_t.trigger_type = 'drawdown' THEN v_ref END,
                'due_date', v_t.due_date::text,
                'previous_value', v_t.last_value,
                'action_note', v_t.action_note)));
        END IF;
    END LOOP;

    -- Roter Faden: vorgemerkte Problemberichte (ausserhalb des Fensters entstanden) im Fenster nachreichen — nur wenn
    -- der Trigger noch scharf ist und weiter scheitert (fail_streak > 0); behoben -> Vormerkung still loeschen.
    IF v_window THEN
        FOR v_t IN
            SELECT * FROM agent.monitor_triggers t
             WHERE t.problem_pending_at IS NOT NULL
             ORDER BY t.id
             FOR UPDATE
        LOOP
            IF v_t.status = 'armed' AND v_t.fail_streak > 0
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_problems) x WHERE (x->>'id')::int = v_t.id) THEN
                SELECT MIN(s.fetched_at) INTO v_first_fail FROM (
                    SELECT o.fetched_at FROM agent.monitor_observations o
                    WHERE o.trigger_id = v_t.id
                    ORDER BY o.fetched_at DESC, o.id DESC
                    LIMIT v_t.fail_streak
                ) s;
                v_problems := v_problems || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                    'id', v_t.id, 'label', v_t.label, 'domain', v_t.domain,
                    'fail_streak', v_t.fail_streak,
                    'reason', (SELECT o.reason FROM agent.monitor_observations o WHERE o.trigger_id = v_t.id
                                ORDER BY o.fetched_at DESC, o.id DESC LIMIT 1),
                    'first_fail', to_char(v_first_fail, 'DD.MM.YYYY'))));
            END IF;
            UPDATE agent.monitor_triggers SET problem_pending_at = NULL WHERE id = v_t.id;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'ok', true, 'checked', v_checked,
        'fired', v_fired, 'info', v_info, 'problems', v_problems);
END;
$$;
