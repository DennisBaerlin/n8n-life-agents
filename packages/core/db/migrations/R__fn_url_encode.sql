-- ============================================================
-- core.fn_url_encode(text) (read-only, IMMUTABLE — Update-Hinweis 2026-10-24)
--   Prozent-Kodierung nach RFC 3986 fuer Query-Werte (UTF-8-Bytes; unreserviert bleiben A-Z a-z 0-9 - _ . ~).
--   Genutzt fuer den vorausgefuellten [Problem melden]-Link (core.fn_update_report). PostgreSQL hat keine eingebaute.
--   RUECKGABE: text ('' bei NULL). Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_url_encode(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_bytes bytea := convert_to(COALESCE(p_text, ''), 'UTF8');
    v_out   text := '';
    v_b     int;
BEGIN
    FOR i IN 0 .. length(v_bytes) - 1 LOOP
        v_b := get_byte(v_bytes, i);
        IF (v_b BETWEEN 48 AND 57) OR (v_b BETWEEN 65 AND 90) OR (v_b BETWEEN 97 AND 122) OR v_b IN (45, 46, 95, 126) THEN
            v_out := v_out || chr(v_b);
        ELSE
            v_out := v_out || '%' || upper(lpad(to_hex(v_b), 2, '0'));
        END IF;
    END LOOP;
    RETURN v_out;
END;
$$;
