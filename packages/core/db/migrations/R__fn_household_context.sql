-- ============================================================
-- fn_household_context (read-only Render — render-at-fetch, nie backen) — WS1b: HEADER-ONLY
--   Liefert NUR den autoritativen Fakten-HEADER der 'family'-Zeile (Personen-Bullets mit
--   Ableitungen Alter/Regelaltersgrenze/Kindergeld). Banner-Zeile, _meta-Stempel, '---' und der
--   woertliche Prosa-Body kommen seit WS1b von der generischen Engine core.fn_fetch_context (die
--   wrappt jeden Renderer uniform) — analog finance.fn_render_plan_facts. UNIFORME Signatur
--   fn(text)->text (Context-Name als Argument; die Engine ruft render_fn(name) ueber core.context_renderers).
--   Ableitungen passieren HIER in SQL — Alter, Regelaltersgrenze (fn_regelaltersgrenze),
--   Kindergeld-Ende (Geburtsdatum + 25 Jahre) — und werden NIE gespeichert (am naechsten Geburtstag
--   waere ein gebackener Wert stale; GENERATED unmoeglich: CURRENT_DATE nicht immutable).
--
--   RUECKGABE: Header-Text ODER NULL (kein family-Kontext / leere Zeile ohne Personen UND ohne Prosa)
--   -> die Engine rendert dann nur den rohen content. Hat die Zeile Prosa aber keine Personen, liefert
--   der Renderer den Fallback '(no persons on record)' (byte-identisch zur Vor-WS1b-Wrap-Ausgabe).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_household_context(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_header TEXT;
    v_body   TEXT;
BEGIN
    SELECT
        string_agg(
            format('- %s %s (%s): geb. %s (Alter: %s)%s%s%s%s',
                pp->>'first_name', pp->>'last_name', pp->>'role',
                to_char((pp->>'birth_date')::date, 'DD.MM.YYYY'),
                date_part('year', age((pp->>'birth_date')::date))::int,
                CASE WHEN pp->>'role' = 'child'
                     THEN format(' · Kindergeld bis %s (max. 25)',
                                 to_char((pp->>'birth_date')::date + INTERVAL '25 years', 'DD.MM.YYYY'))
                     ELSE format(' · Regelaltersrente ab %s',
                                 to_char(agent.fn_regelaltersgrenze((pp->>'birth_date')::date), 'MM/YYYY'))
                END,
                CASE WHEN pp ? 'citizenships' AND jsonb_typeof(pp->'citizenships') = 'array'
                     THEN ' · Staatsangehörigkeit: ' ||
                          (SELECT string_agg(x, '+') FROM jsonb_array_elements_text(pp->'citizenships') x)
                     ELSE '' END,
                CASE WHEN COALESCE(pp->>'language','') <> ''
                     THEN ' · Sprache: ' || (pp->>'language') ELSE '' END,
                CASE WHEN COALESCE(pp->>'as_of','') <> ''
                     THEN format(' (Stand: %s)', pp->>'as_of') ELSE '' END
            ),
            E'\n' ORDER BY CASE pp->>'role' WHEN 'owner' THEN 0 WHEN 'partner' THEN 1 ELSE 2 END, pp->>'person_id')
            FILTER (WHERE pp IS NOT NULL),   -- defensiv (Review A3): leere persons -> kein Junk-Bullet
        c.content
    INTO v_header, v_body
    FROM agent.core_contexts c
         LEFT JOIN LATERAL jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) pp ON TRUE
    WHERE c.name = p_name
    GROUP BY c.content;

    IF v_header IS NULL AND v_body IS NULL THEN
        RETURN NULL;  -- kein family-Kontext / leere Zeile ohne Personen UND ohne Prosa -> Engine: nur roher content (hier NULL)
    END IF;
    -- Header-only: die Engine setzt Banner + _meta-Stempel + '---' + Prosa-Body davor/dahinter.
    RETURN COALESCE(v_header, '(no persons on record)');
END;
$$;
