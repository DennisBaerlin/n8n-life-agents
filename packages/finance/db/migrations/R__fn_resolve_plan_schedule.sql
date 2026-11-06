-- ============================================================
-- fn_resolve_plan_schedule (READ — gespeicherter Sparplan-Rhythmus aus Nutzer-Rhythmus + Depot-Kalender)
--   Der Nutzer nennt den Rhythmus wie in der Bank-App ("woechentlich", "zweimal im Monat", "monatlich"); die DB
--   leitet daraus den gespeicherten Rhythmus ab (Das LLM rechnet nicht). Genutzt von fn_create_savings_plan und
--   fn_set_savings_plan (EINE Ableitung).
--   Kalender K = Nutzer-Antwort p_days_input (falls genannt) > accounts.plan_execution_days > fn_broker_plan_days(bank).
--     p_days_input = roher Nutzer-Fakt nach needs_calendar: Monatstage ("2,9,16,23", "20., 5.", "2, 9, 16 und 23")
--     oder 'none' = kein fester Kalender. Pruefung per Regex VOR dem Cast -> {ok:false} statt RAISE.
--   Ableitung:
--     month/n          -> Einzeltag = schedule_day_of_month bzw. Tag der ersten Ausfuehrung; bei festem K muss er
--                         in K liegen. Nie eine Nachfrage (monatlich ist eindeutig), auch bei unbekanntem K.
--     week/1 | week/2  -> Ziel 4 bzw. 2 Termine je Monat. Festes K: Schritt = |K| / Ziel (ganzzahlig >= 1), Tage =
--                         jedes Schritt-te Element von K ab dem Starttag -> month/1 + schedule_days_of_month (bei
--                         nur einem Tag: Einzeltag). K = '{}' -> unveraendert (echte 7-/14-Tage-Abstaende).
--                         K unbekannt -> {ok:false, needs_calendar:true} (der Agent fragt einmal nach den Terminen).
--     sonst (day, week/>=3, year) bei festem K -> {ok:false}; ohne festes K unveraendert.
--     Erste Ausfuehrung nicht auf einem Tag von K -> {ok:false, next_possible_date}.
--   RUECKGABE {ok, schedule_unit, schedule_interval, schedule_day_of_month, schedule_days_of_month (Array|null),
--     calendar (Array|null = K), calendar_changed (K ist am Depot zu speichern)} bzw. {ok:false, reason,
--     code (needs_calendar | off_calendar | rhythm_not_offered | -), needs_calendar?, next_possible_date?}. STABLE, schreibt nie (der Aufrufer speichert K im selben Write).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_plan_schedule(
    p_depot_id   int,
    p_unit       finance.schedule_unit,
    p_interval   smallint,
    p_dom        smallint,
    p_first      date,
    p_days_input text
) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_n      smallint := GREATEST(COALESCE(p_interval, 1), 1);
    v_stored smallint[];
    v_bank   text;
    v_cal    smallint[];
    v_raw    text := lower(btrim(COALESCE(p_days_input, '')));
    v_day    smallint := EXTRACT(DAY FROM p_first)::smallint;
    v_target int;
    v_step   int;
    v_pos    int;
    v_days   smallint[];
    v_next   date;
    v_list   text;
BEGIN
    SELECT a.plan_execution_days, a.bank INTO v_stored, v_bank FROM finance.accounts a WHERE a.id = p_depot_id;

    -- 1. Kalender K bestimmen
    IF v_raw <> '' THEN
        IF v_raw IN ('none', 'no') THEN
            v_cal := '{}';
        ELSE
            -- "am 2., 9., 16. und 23." / "2nd, 9th, 16th and 23rd" -> "2, 9, 16, 23": Punkte und Ordinal-Endungen weg,
            -- Fuellwoerter (am/on/the) weg, "und"/"and"/"&" als Trenner. Alles andere bleibt -> Regex lehnt ab.
            v_raw := replace(v_raw, '.', '');
            v_raw := regexp_replace(v_raw, '([0-9])(st|nd|rd|th)\M', '\1', 'g');
            v_raw := regexp_replace(v_raw, '\m(am|on|the)\M', ' ', 'g');
            v_raw := regexp_replace(v_raw, '\s*(\mund\M|\mand\M|&)\s*', ',', 'g');
            IF v_raw !~ '^\s*[0-9]{1,2}(\s*[,;/ ]\s*[0-9]{1,2})*\s*$' THEN
                RETURN jsonb_build_object('ok', false,
                    'reason', 'depot_execution_days must list the days of the month the bank executes savings plans '
                           || '(e.g. "2,9,16,23"), or "none" if it runs every 7 days; got: ' || p_days_input);
            END IF;
            v_cal := ARRAY(SELECT DISTINCT x::smallint FROM regexp_split_to_table(btrim(v_raw), '\s*[,;/ ]\s*') x
                           WHERE x <> '' ORDER BY 1);
            IF NOT finance.fn_valid_schedule_days(v_cal) THEN
                RETURN jsonb_build_object('ok', false,
                    'reason', 'Execution days must be between 1 and 28 (got ' || p_days_input || ').');
            END IF;
        END IF;
    ELSE
        v_cal := COALESCE(v_stored, finance.fn_broker_plan_days(v_bank));
    END IF;

    -- Naechster moeglicher Kalendertag ab p_first (fuer Ablehnungen; nur bei festem K)
    IF cardinality(v_cal) > 0 THEN
        SELECT min(c) INTO v_next FROM (
            SELECT (date_trunc('month', p_first) + (m || ' months')::interval + ((d - 1) || ' days')::interval)::date AS c
            FROM unnest(v_cal) d, generate_series(0, 1) m) x
        WHERE x.c >= p_first;
        v_list := array_to_string(v_cal, ', ');
    END IF;

    -- 2. Ableitung
    IF p_unit = 'month' THEN
        IF cardinality(v_cal) > 0 THEN
            IF p_dom IS NOT NULL AND NOT (p_dom = ANY (v_cal)) THEN
                RETURN jsonb_build_object('ok', false, 'code', 'off_calendar',
                    'reason', 'This bank executes savings plans only on these days of the month: ' || v_list
                           || '. The fixed day ' || p_dom || ' is not one of them; leave schedule_day_of_month empty '
                           || '(the day of the first execution is used) or ask the user which of these days to use.');
            END IF;
            IF NOT (v_day = ANY (v_cal)) THEN
                RETURN jsonb_build_object('ok', false, 'code', 'off_calendar', 'next_possible_date', v_next,
                    'reason', 'This bank executes savings plans only on these days of the month: ' || v_list
                           || '. The first execution ' || p_first || ' is not one of them; the next possible date is '
                           || v_next || '. Ask the user which date to use.');
            END IF;
            RETURN jsonb_build_object('ok', true, 'schedule_unit', 'month', 'schedule_interval', v_n,
                'schedule_day_of_month', COALESCE(p_dom, v_day), 'schedule_days_of_month', NULL,
                'calendar', to_jsonb(v_cal), 'calendar_changed', v_cal IS DISTINCT FROM v_stored);
        END IF;
        RETURN jsonb_build_object('ok', true, 'schedule_unit', 'month', 'schedule_interval', v_n,
            'schedule_day_of_month', p_dom, 'schedule_days_of_month', NULL,
            'calendar', to_jsonb(v_cal), 'calendar_changed', v_cal IS DISTINCT FROM v_stored AND v_cal IS NOT NULL);
    END IF;

    IF p_unit = 'week' AND v_n IN (1, 2) THEN
        IF v_cal IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'needs_calendar', 'needs_calendar', true,
                'reason', 'It is unknown how this bank schedules ' || CASE v_n WHEN 1 THEN 'weekly' ELSE 'bi-weekly' END
                       || ' savings plans: some banks run them every 7 days, others on fixed days of the month '
                       || '(e.g. 2nd, 9th, 16th and 23rd). Ask the user once which next execution dates the bank app '
                       || 'shows, then call again with depot_execution_days (the days of the month, or "none" if the '
                       || 'plan runs every 7 days). It is remembered for this depot.');
        END IF;
        IF cardinality(v_cal) > 0 THEN
            v_target := CASE v_n WHEN 1 THEN 4 ELSE 2 END;
            IF cardinality(v_cal) < v_target OR cardinality(v_cal) % v_target <> 0 THEN
                RETURN jsonb_build_object('ok', false, 'code', 'rhythm_not_offered',
                    'reason', 'This bank executes savings plans only on these days of the month: ' || v_list
                           || ' (' || cardinality(v_cal) || ' per month), so a '
                           || CASE v_n WHEN 1 THEN 'weekly (4 per month)' ELSE 'twice-monthly (2 per month)' END
                           || ' plan is not possible. Ask the user for a rhythm the bank offers.');
            END IF;
            v_pos := array_position(v_cal, v_day);
            IF v_pos IS NULL THEN
                RETURN jsonb_build_object('ok', false, 'code', 'off_calendar', 'next_possible_date', v_next,
                    'reason', 'This bank executes savings plans only on these days of the month: ' || v_list
                           || '. The first execution ' || p_first || ' is not one of them; the next possible date is '
                           || v_next || '. Ask the user which date to use.');
            END IF;
            v_step := cardinality(v_cal) / v_target;
            v_days := ARRAY(SELECT v_cal[i] FROM generate_subscripts(v_cal, 1) i
                            WHERE (i - v_pos) % v_step = 0 ORDER BY v_cal[i]);
            RETURN jsonb_build_object('ok', true, 'schedule_unit', 'month', 'schedule_interval', 1,
                'schedule_day_of_month', CASE WHEN cardinality(v_days) = 1 THEN v_days[1] END,
                'schedule_days_of_month', CASE WHEN cardinality(v_days) > 1 THEN to_jsonb(v_days) END,
                'calendar', to_jsonb(v_cal), 'calendar_changed', v_cal IS DISTINCT FROM v_stored);
        END IF;
        -- K = '{}': echte Intervalle
        RETURN jsonb_build_object('ok', true, 'schedule_unit', 'week', 'schedule_interval', v_n,
            'schedule_day_of_month', p_dom, 'schedule_days_of_month', NULL,
            'calendar', to_jsonb(v_cal), 'calendar_changed', v_cal IS DISTINCT FROM v_stored);
    END IF;

    -- day, week/>=3, year
    IF cardinality(v_cal) > 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'rhythm_not_offered',
            'reason', 'This bank executes savings plans only on these days of the month: ' || v_list
                   || '. Possible rhythms: monthly or every few months on one of these days'
                   || CASE WHEN cardinality(v_cal) % 2 = 0 THEN ', twice a month' ELSE '' END
                   || CASE WHEN cardinality(v_cal) % 4 = 0 THEN ', weekly (all ' || cardinality(v_cal) || ' days)' ELSE '' END
                   || '. Ask the user which one.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'schedule_unit', p_unit, 'schedule_interval', v_n,
        'schedule_day_of_month', p_dom, 'schedule_days_of_month', NULL,
        'calendar', to_jsonb(v_cal), 'calendar_changed', v_cal IS DISTINCT FROM v_stored AND v_cal IS NOT NULL);
END;
$$;
