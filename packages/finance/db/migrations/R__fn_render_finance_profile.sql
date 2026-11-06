-- ============================================================
-- finance.fn_render_finance_profile (read-only Render — joint BEIDE Sidecars) — WS1b: HEADER-ONLY
--   Phase A: aus dem Core (vormals agent.fn_finance_profile_context; core:V019 droppt sie) ins finance-Paket
--   gezogen — Registrierung im finance-Manifest context_renderers (Core kennt kein Paket). Laeuft im DEFINER
--   core.fn_fetch_context (Owner=Superuser) -> liest family + ruft agent.fn_regelaltersgrenze ohne eigenen
--   Grant (Praezedenz finance.fn_render_plan_facts, docs/reference/packages.md Cross-Paket-Read Oberflaeche A).
--   Liefert NUR den autoritativen Fakten-HEADER der 'finance_profile'-Zeile (advisor-scoped):
--   Wunsch-Rentenjahr (Join family.birth_date x fp.planned_retirement_age), Delta zur Regelaltersgrenze,
--   Vorsorgesystem/Steuerklasse/.... Banner, _meta-Stempel, '---' und der Prosa-Body kommen seit WS1b
--   von der generischen Engine core.fn_fetch_context. UNIFORME Signatur fn(text)->text.
--   Single-Writer-Prinzip: Geburtsdaten leben NUR in family — diese Fn joint, dupliziert nie.
--
--   RUECKGABE: Header-Text ODER NULL (kein finance_profile / leere Zeile ohne Personen UND ohne Prosa)
--   -> die Engine rendert dann nur den rohen content. Leere persons mit Prosa -> Fallback-Zeile.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_render_finance_profile(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_header TEXT;
    v_body   TEXT;
BEGIN
    SELECT
        string_agg(
            format('- %s%s%s%s%s%s%s',
                COALESCE(fam.full_name, fp->>'person_id'),
                CASE WHEN jsonb_typeof(fp->'planned_retirement_age') = 'number' AND fam.birth_date IS NOT NULL
                     THEN format(': geplantes Rentenalter %s → %s (Regelgrenze %s)',
                            fp->>'planned_retirement_age',
                            to_char(fam.birth_date + make_interval(years => (fp->>'planned_retirement_age')::int), 'YYYY'),
                            to_char(agent.fn_regelaltersgrenze(fam.birth_date), 'MM/YYYY'))
                     WHEN jsonb_typeof(fp->'planned_retirement_age') = 'number'
                     THEN ': geplantes Rentenalter ' || (fp->>'planned_retirement_age')
                     ELSE '' END,
                CASE WHEN COALESCE(fp->>'vorsorgesystem','') <> ''
                     THEN ' · Vorsorgesystem: ' || (fp->>'vorsorgesystem') ELSE '' END,
                CASE WHEN jsonb_typeof(fp->'steuerklasse') = 'number'
                     THEN ' · Steuerklasse: ' || (fp->>'steuerklasse') ELSE '' END,
                CASE WHEN fp ? 'kirchensteuer' AND jsonb_typeof(fp->'kirchensteuer') <> 'null'
                     THEN ' · Kirchensteuer: ' || CASE WHEN (fp->>'kirchensteuer')::boolean THEN 'ja' ELSE 'nein' END
                     ELSE '' END,
                CASE WHEN COALESCE(fp->>'tax_residency','') <> ''
                     THEN ' · steuerliche Ansässigkeit: ' || (fp->>'tax_residency') ELSE '' END,
                CASE WHEN COALESCE(fp->>'as_of','') <> ''
                     THEN format(' (Stand: %s)', fp->>'as_of') ELSE '' END
            ),
            E'\n' ORDER BY fp->>'person_id')
            FILTER (WHERE fp IS NOT NULL),   -- leeres persons-Array: LEFT JOIN liefert 1 NULL-Zeile -> ohne Filter ein Junk-"- "-Bullet (Review A3)
        c.content
    INTO v_header, v_body
    FROM agent.core_contexts c
         LEFT JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.metadata->'facts'->'persons') = 'array'
                                                     THEN c.metadata->'facts'->'persons' ELSE '[]'::jsonb END) fp ON TRUE
         LEFT JOIN LATERAL (
             SELECT (pp->>'first_name') || ' ' || (pp->>'last_name') AS full_name,
                    (pp->>'birth_date')::date AS birth_date
             FROM agent.core_contexts cf,
                  jsonb_array_elements(COALESCE(cf.metadata->'facts'->'persons','[]'::jsonb)) pp
             WHERE cf.name = 'family' AND pp->>'person_id' = fp->>'person_id'
             LIMIT 1
         ) fam ON TRUE
    WHERE c.name = p_name
    GROUP BY c.content;

    IF v_header IS NULL AND v_body IS NULL THEN
        RETURN NULL;
    END IF;
    -- Header-only: die Engine setzt Banner + _meta-Stempel + '---' + Prosa-Body davor/dahinter.
    RETURN COALESCE(v_header, '(no person-level finance facts on record)');
END;
$$;
