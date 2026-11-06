-- ============================================================
-- core.fn_resolve_fact_dates (relative Zeitangaben in einem Fakten-/Plan-jsonb aufloesen)
--   Rekursiv ueber Objekte und Arrays: jeder STRING-Wert unter einem Key, der auf "_date" endet oder "since"
--   heisst und nicht schon absolut ist (YYYY, YYYY-MM, YYYY-MM-DD), laeuft durch core.fn_resolve_date.
--   GENAUIGKEIT FOLGT DER ANGABE: ein Offset in Jahren ergibt YYYY, in Monaten YYYY-MM, alles andere (Tage,
--   Wochen, Wochentag, today) den Tag. So wird aus "mein Sohn ist 5" (birth_date "-5 years") kein erfundener
--   Geburtstag, sondern "2021" — das der family-Validator als Geburtsdatum ablehnt (der Agent fragt nach).
--   Nicht aufloesbare Werte bleiben unveraendert (der Validator lehnt sie dann mit Grund ab); andere Keys,
--   Nicht-Strings und JSON-null bleiben unberuehrt. Keine Paket-Keys im Core: die Regel haengt nur am Suffix.
--   Aufrufer: agent.fn_set_context_facts (facts), agent.fn_advisor_save_section (section_data) und die
--   Tool-Knoten "Resolve dates" VOR der Karte (Karte = Speicher, ein Aufloesungszeitpunkt). Idempotent.
--   STABLE, INVOKER. Tests: tests/db/core/test_fn_resolve_date.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_resolve_fact_dates(p jsonb, p_today date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_out  jsonb;
    r      record;
    v_s    text;
    v_d    date;
    v_unit text;
BEGIN
    IF p IS NULL THEN
        RETURN NULL;
    END IF;
    IF jsonb_typeof(p) = 'array' THEN
        SELECT COALESCE(jsonb_agg(core.fn_resolve_fact_dates(x.e, p_today) ORDER BY x.o), '[]'::jsonb)
          INTO v_out
          FROM jsonb_array_elements(p) WITH ORDINALITY AS x(e, o);
        RETURN v_out;
    END IF;
    IF jsonb_typeof(p) <> 'object' THEN
        RETURN p;
    END IF;

    v_out := '{}'::jsonb;
    FOR r IN SELECT key, value FROM jsonb_each(p) LOOP
        IF (r.key ~ '_date$' OR r.key = 'since') AND jsonb_typeof(r.value) = 'string' THEN
            v_s := r.value #>> '{}';
            IF btrim(v_s) !~ '^\d{4}(-\d{2}(-\d{2})?)?$' THEN
                v_d := core.fn_resolve_date(v_s, p_today);
                IF v_d IS NOT NULL THEN
                    v_unit := substring(lower(v_s) FROM '(year|month)s?');
                    v_out := v_out || jsonb_build_object(r.key, to_char(v_d,
                        CASE v_unit WHEN 'year' THEN 'YYYY' WHEN 'month' THEN 'YYYY-MM' ELSE 'YYYY-MM-DD' END));
                    CONTINUE;
                END IF;
            END IF;
            v_out := v_out || jsonb_build_object(r.key, r.value);
        ELSE
            v_out := v_out || jsonb_build_object(r.key, core.fn_resolve_fact_dates(r.value, p_today));
        END IF;
    END LOOP;
    RETURN v_out;
END;
$$;
