-- ============================================================
-- fn_real_estate_facts_reason (VALIDIERUNG, Instandhaltungsruecklage 2026-10-27)
--   Die EINE Pruefung der Gebaeude-Fakten einer Immobilie fuer fn_create_real_estate, fn_set_real_estate und die
--   Import-Validierung: living_area_m2 (Zahl > 0, Punkt als Dezimaltrenner) und year_built (vierstelliges Jahr,
--   1800 bis heute; "nicht in der Zukunft" kann der CHECK nicht, er haelt nur 1800-2200). Leer = nicht gesetzt.
--   RUECKGABE: NULL (ok) oder ein englischer Grund fuer {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_real_estate_facts_reason(p jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_area TEXT := NULLIF(btrim(p->>'living_area_m2'), '');
    v_year TEXT := NULLIF(btrim(p->>'year_built'), '');
    v_bad  BOOLEAN;
BEGIN
    -- CASE erzwingt die Reihenfolge (OR wertet nicht garantiert links zuerst aus): erst das Muster, dann der Cast.
    -- Als Zuweisung, weil PL/pgSQL die IF-Bedingung beim ersten THEN abschneidet (auch dem THEN eines CASE).
    v_bad := CASE WHEN v_area IS NULL THEN false
                  WHEN v_area ~ '^[0-9]{1,6}([.][0-9]{1,2})?$' THEN v_area::numeric <= 0
                  ELSE true END;
    IF v_bad THEN
        RETURN 'The living area must be a positive number of square metres (e.g. 120 or 87.5), got "' || v_area || '".';
    END IF;
    v_bad := CASE WHEN v_year IS NULL THEN false
                  WHEN v_year ~ '^[0-9]{4}$' THEN v_year::int < 1800 OR v_year::int > EXTRACT(YEAR FROM core.fn_today())::int
                  ELSE true END;
    IF v_bad THEN
        RETURN 'The year built must be a four-digit year between 1800 and this year, got "' || v_year || '".';
    END IF;
    RETURN NULL;
END;
$$;
