-- ============================================================
-- fn_monitor_drawdown_reference (READ)
--   Die eine Adresse fuer den Hoechststand (reference_value) eines Drawdown-Waechters beim Anlegen. Probelauf vor der
--   Karte, Karten-Zeile und Write lesen ihn ueber fn_create_monitor_trigger nur von hier; das Modell liefert ihn nie.
--     * sql mit spec.history_query (Reihe derselben Groesse: Zeilen (Datum, Wert)): laufendes Maximum seit since,
--       mindestens der heutige Probe-Wert. Die Reihe laeuft wie die Beschaffung strukturell read-only ueber
--       agent.fn_monitor_ro_eval (Shape-Guard wie acquisition_sql).
--     * jede andere Methode (web_search, Paket-Methoden ohne gespeicherte Reihe): heutiger Probe-Wert, gemessen ab heute.
--     * ohne Reihe und ohne Probe-Wert: value NULL (die erste saubere Messung setzt ihn, Ratchet in fn_monitor_evaluate).
--   Eingabe jsonb: method (Pflicht), spec (gespeicherte acquisition_spec), since (optional, Datum: Reihe ab hier),
--     current_value + current_as_of (optional: der Probe-Wert vor der Karte).
--   Rueckgabe: {ok:true, value, as_of, since, basis: history|current|none};
--     {ok:false, reason} wenn since kein Datum oder current_value keine Zahl ist, history_query kein einzelnes SELECT ist
--     oder nicht (Datum, Wert) liefert.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_drawdown_reference(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_method  TEXT := COALESCE(NULLIF(trim(p->>'method'), ''), 'none');
    v_hq      TEXT := regexp_replace(trim(COALESCE(p#>>'{spec,history_query}', '')), ';\s*$', '');
    v_since   DATE;
    v_cur     NUMERIC;
    v_cur_at  DATE;
    v_from    TEXT;
    v_peak    NUMERIC;
    v_peak_at NUMERIC;
    v_first   NUMERIC;
    v_path    TEXT := current_setting('search_path');
BEGIN
    BEGIN
        v_since  := NULLIF(trim(COALESCE(p->>'since', '')), '')::date;
        v_cur    := NULLIF(trim(COALESCE(p->>'current_value', '')), '')::numeric;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'since must be a date and current_value a number');
    END;
    -- as_of einer Web-Probe ist freier Text der Quelle: unlesbar -> heute
    BEGIN
        v_cur_at := NULLIF(trim(COALESCE(p->>'current_as_of', '')), '')::date;
    EXCEPTION WHEN OTHERS THEN
        v_cur_at := NULL;
    END;
    v_cur_at := COALESCE(v_cur_at, core.fn_today());

    IF v_method = 'sql' AND v_hq <> '' THEN
        IF v_hq !~* '^\s*select\y' OR position(';' in v_hq) > 0 OR length(v_hq) > 2000 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'history_sql rejected: must be a single SELECT (no semicolons, max 2000 chars) returning rows (date, value)');
        END IF;
        v_from := format('FROM (%s) AS h(d, v) WHERE h.v IS NOT NULL AND h.d IS NOT NULL%s', v_hq,
                         CASE WHEN v_since IS NOT NULL THEN format(' AND h.d::date >= %L::date', v_since) ELSE '' END);
        BEGIN
            v_peak    := agent.fn_monitor_ro_eval(format('SELECT max(h.v::numeric) %s', v_from), v_path);
            v_peak_at := agent.fn_monitor_ro_eval(
                format('SELECT to_char(h.d::date, ''YYYYMMDD'')::numeric %s ORDER BY h.v::numeric DESC, h.d::date DESC LIMIT 1', v_from), v_path);
            v_first   := agent.fn_monitor_ro_eval(format('SELECT to_char(min(h.d::date), ''YYYYMMDD'')::numeric %s', v_from), v_path);
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'history_sql failed: ' || SQLERRM || ' - it must return rows (date, value) of the same series as acquisition_sql');
        END;
        IF v_peak IS NOT NULL THEN
            IF v_cur IS NOT NULL AND v_cur > v_peak THEN
                v_peak := v_cur;
                v_peak_at := to_char(v_cur_at, 'YYYYMMDD')::numeric;
            END IF;
            RETURN jsonb_build_object('ok', true, 'value', v_peak,
                'as_of', to_date(v_peak_at::text, 'YYYYMMDD')::text,
                'since', COALESCE(v_since, to_date(v_first::text, 'YYYYMMDD'))::text,
                'basis', 'history');
        END IF;
    END IF;

    IF v_cur IS NOT NULL THEN
        RETURN jsonb_build_object('ok', true, 'value', v_cur, 'as_of', v_cur_at::text,
            'since', core.fn_today()::text, 'basis', 'current');
    END IF;
    RETURN jsonb_build_object('ok', true, 'value', NULL, 'as_of', NULL, 'since', NULL, 'basis', 'none');
END;
$$;

-- Die eine Drawdown-Regel (Prozent unter dem Hoechststand, 2 Stellen): fn_monitor_evaluate feuert bei
-- fn_monitor_drawdown_pct(ref, wert) >= drawdown_pct; die Meldegrenze der Karte folgt aus derselben Regel.
CREATE OR REPLACE FUNCTION agent.fn_monitor_drawdown_pct(p_ref numeric, p_value numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_ref > 0 THEN round((p_ref - p_value) / p_ref * 100, 2) END
$$;

-- Meldegrenze: der hoechste Wert in Anzeige-Genauigkeit (Stellen des Hoechststands, mindestens 2), bei dem die Regel
-- oben feuert; abgerundet, damit "Meldung bei X oder tiefer" fuer X selbst stimmt.
CREATE OR REPLACE FUNCTION agent.fn_monitor_drawdown_alert_level(p_ref numeric, p_pct numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_d   INT := GREATEST(2, scale(trim_scale(p_ref)));
    v_lvl NUMERIC := trunc(p_ref * (1 - p_pct / 100), GREATEST(2, scale(trim_scale(p_ref))));
BEGIN
    IF p_ref IS NULL OR p_ref <= 0 OR p_pct IS NULL THEN
        RETURN NULL;
    END IF;
    WHILE v_lvl > 0 AND agent.fn_monitor_drawdown_pct(p_ref, v_lvl) < p_pct LOOP
        v_lvl := v_lvl - 10::numeric ^ (-v_d);
    END LOOP;
    RETURN v_lvl;
END;
$$;

-- Hilfs-fn der Karten-Zeilen eines Waechter-Werts: tpl-Parameter {value, unit}. Ein ISO-Waehrungscode (drei
-- Grossbuchstaben; MWh/kWh/bps sind keine) wird Geldbetrag im Locale des Empfaengers (ab 1, darunter fielen
-- Nachkommastellen weg), sonst Zahl mit den Stellen des Werts + Einheit.
CREATE OR REPLACE FUNCTION agent.fn_monitor_amount_params(p_value numeric, p_unit text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_unit TEXT := NULLIF(trim(COALESCE(p_unit, '')), '');
BEGIN
    IF v_unit ~ '^[A-Z]{3}$' AND abs(p_value) >= 1 THEN
        RETURN jsonb_build_object('value', core.fn_ui_money(p_value, v_unit), 'unit', '');
    END IF;
    RETURN jsonb_build_object('value', core.fn_ui_num(p_value, GREATEST(2, scale(trim_scale(p_value)))),
                              'unit', CASE WHEN v_unit IS NULL THEN '' ELSE ' ' || v_unit END);
END;
$$;
