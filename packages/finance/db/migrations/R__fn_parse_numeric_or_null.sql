-- ============================================================
-- fn_parse_numeric_or_null (rein, IMMUTABLE) -- freie Zahl-Eingabe -> numeric oder NULL (nie ein Cast-RAISE)
--   fn_parse_de_numeric kanonisiert deutsche/plain Schreibweise ("1.234,50" -> 1234.50) und laesst Unlesbares als Rohtext
--   stehen; diese fn prueft das Ergebnis mit pg_input_is_valid und liefert dann NULL. Fuer Write-fns, deren Tool-Eingabe
--   ein freier String ist: NULL -> die fn meldet {ok:false} (korrigierbare Ablehnung statt Owner-Alert).
--   p_thousands_dot wie fn_parse_de_numeric (TRUE nur fuer Geldbetraege).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_parse_numeric_or_null(p_raw text, p_thousands_dot boolean)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_txt TEXT := finance.fn_parse_de_numeric(NULLIF(btrim(p_raw), ''), p_thousands_dot);
BEGIN
    IF v_txt IS NULL OR NOT pg_input_is_valid(v_txt, 'numeric') THEN RETURN NULL; END IF;
    RETURN v_txt::numeric;
END;
$$;
