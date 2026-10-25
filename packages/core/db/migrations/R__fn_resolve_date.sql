-- ============================================================
-- core.fn_resolve_date (DIE EINE ADRESSE FUER "RELATIVE ZEITANGABE -> DATUM")
--   Das LLM rechnet nie (auch keine Datums-Arithmetik, Root-CLAUDE.md): es UEBERSETZT die Nutzer-Angabe
--   ("vor drei Tagen", "in drei Wochen", "letzten Freitag") in eine feste Form, die DB rechnet hier.
--   Akzeptiert (case-insensitiv, getrimmt):
--     * YYYY-MM-DD (ungueltiges Datum wie 2024-02-30 -> NULL, kein RAISE)
--     * today | yesterday | tomorrow
--     * [+-]N <unit> | in N <unit> | N <unit> ago   mit <unit> = day(s)|week(s)|month(s)|year(s), N <= 9999
--       (Vorzeichen zusammen mit "ago" = Doppel-Negation -> NULL; ohne Richtung ("3 days") -> NULL)
--     * next|last <weekday> (englisch) = 1..7 Tage STRIKT danach bzw. davor (gleicher Wochentag = +-7)
--   Sonst NULL — der Aufrufer antwortet {ok:false, reason} mit dem Format-Hinweis. Bewusst keine Freitext-NLP
--   (de/en/ko-Zahlwoerter in SQL waeren fragil). Offsets per make_interval (unabhaengig von IntervalStyle);
--   Monatsende klemmt wie Postgres (31.01. + 1 month = 28.02.).
--   p_today = Bezugstag (NULL/Default = core.fn_today(), Haushalts-Zeitzone); als Parameter fuer deterministische Tests.
--   STABLE, INVOKER, ohne Tabellenzugriff. Paket-Rollen: EXECUTE-Grant in core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_resolve_date.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_resolve_date(p_text text, p_today date DEFAULT NULL)
RETURNS date
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v      text := lower(btrim(COALESCE(p_text, '')));
    m      text[];
    v_n    int;
    v_dow  int;
    v_tgt  int;
    v_diff int;
BEGIN
    IF v = '' THEN
        RETURN NULL;
    END IF;
    p_today := COALESCE(p_today, core.fn_today());   -- late-bound: R__fn_today sortiert alphabetisch NACH dieser Datei

    IF v ~ '^\d{4}-\d{2}-\d{2}$' THEN
        BEGIN
            RETURN v::date;                   -- ISO ist DateStyle-unabhaengig; 2024-02-30 wirft -> NULL
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END IF;

    IF v = 'today' THEN RETURN p_today; END IF;
    IF v = 'yesterday' THEN RETURN p_today - 1; END IF;
    IF v = 'tomorrow' THEN RETURN p_today + 1; END IF;

    m := regexp_match(v, '^(\+|-|in\s+)?\s*(\d{1,4})\s*(day|week|month|year)s?(\s+ago)?$');
    IF m IS NOT NULL THEN
        IF m[1] IS NOT NULL AND m[4] IS NOT NULL THEN
            RETURN NULL;                      -- "-3 days ago": Doppel-Negation
        END IF;
        IF m[1] IS NULL AND m[4] IS NULL THEN
            RETURN NULL;                      -- "3 days": Richtung fehlt
        END IF;
        v_n := m[2]::int;
        IF m[1] = '-' OR m[4] IS NOT NULL THEN
            v_n := -v_n;
        END IF;
        RETURN (p_today + CASE m[3]
                    WHEN 'day'   THEN make_interval(days   => v_n)
                    WHEN 'week'  THEN make_interval(weeks  => v_n)
                    WHEN 'month' THEN make_interval(months => v_n)
                    ELSE              make_interval(years  => v_n)
                END)::date;
    END IF;

    m := regexp_match(v, '^(next|last)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)$');
    IF m IS NOT NULL THEN
        v_tgt := array_position(ARRAY['sunday','monday','tuesday','wednesday','thursday','friday','saturday'], m[2]) - 1;
        v_dow := extract(dow FROM p_today)::int;
        IF m[1] = 'next' THEN
            v_diff := (v_tgt - v_dow + 7) % 7;
            RETURN p_today + CASE WHEN v_diff = 0 THEN 7 ELSE v_diff END;
        END IF;
        v_diff := (v_dow - v_tgt + 7) % 7;
        RETURN p_today - CASE WHEN v_diff = 0 THEN 7 ELSE v_diff END;
    END IF;

    RETURN NULL;
END;
$$;
