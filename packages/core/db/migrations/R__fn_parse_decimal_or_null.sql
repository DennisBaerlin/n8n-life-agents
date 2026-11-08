-- ============================================================
-- fn_parse_decimal_or_null (rein, IMMUTABLE) -- freie Dezimal-Eingabe eines Monitor-Triggers -> numeric oder NULL
--   Schwellen, Prozente und Plausibilitaets-Grenzen kommen als freier Text vom Modell; ein deutsches Komma ("1,5")
--   wird Dezimalpunkt, Leerzeichen fallen weg. Unlesbares (auch "1.234,5" oder Einheiten) -> NULL, nie ein Cast-RAISE:
--   der Aufrufer meldet dann {ok:false} (korrigierbare Ablehnung statt Owner-Alert). Leer/NULL -> NULL.
--   Bewusst ohne Tausender-Punkt-Regel (finance.fn_parse_numeric_or_null ist paket-eigen und fuer Geldbetraege).
--   Aufrufer: agent.fn_create_monitor_trigger, agent.fn_set_monitor_trigger.
--   Tests: tests/db/core/test_fn_parse_decimal_or_null.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_parse_decimal_or_null(p_raw text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_txt TEXT := replace(replace(btrim(COALESCE(p_raw, '')), ' ', ''), ',', '.');
BEGIN
    IF v_txt = '' OR NOT pg_input_is_valid(v_txt, 'numeric') THEN RETURN NULL; END IF;
    RETURN v_txt::numeric;
END;
$$;
