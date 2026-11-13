-- ============================================================
-- core.fn_get_next_step_example(p_person_id, p_order) — eine Beispielfrage fuer diese Person (READ)
--   Konvention je Paket: <pkg>.fn_next_step_example(p_person_id text) RETURNS text liefert einen Katalog-Key oder NULL;
--   das Paket entscheidet Datenlage und Sichtrecht (z. B. Haushalts-Sicht nur owner/partner, Kinder nie Geld-Fragen).
--   Gefragt werden nur aktive Pakete aus core.package_registry (p_order sortiert nur: Paketname vor dem ':' der
--   Abschnitts-Keys, sonst alphabetisch), und eine Paket-fn nur, wenn pg_proc belegt, dass sie sicher angelegt ist:
--   Eigentuemer = Eigentuemer des Schemas core, SECURITY DEFINER, search_path gepinnt. Grund: diese fn laeuft als
--   Eigentuemer; eine von einer Paket-Rolle angelegte fn liefe sonst mit core-Rechten.
--   Ein Key zaehlt nur, wenn er mit '<pkg>.' beginnt und im Katalog (core.ui_texts, Sprache der Person -> en) steht und
--   der Text keinen {platzhalter} traegt; sonst und bei jedem Fehler der Paket-fn weiter zum naechsten Paket.
--   Ohne Treffer: core.next_step.example_neutral. Ohne Person (NULL) -> NULL.
--   Rueckgabe text in der Sprache der Person (agent.fn_person_lang). STABLE, SECURITY DEFINER, search_path gepinnt.
--   Tests: tests/db/core/test_fn_get_next_step.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_get_next_step_example(p_person_id text, p_order jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_lang  text;
    v_pkg   text;
    v_fn    regprocedure;
    v_key   text;
    v_text  text;
    v_owner oid := (SELECT n.nspowner FROM pg_catalog.pg_namespace n WHERE n.nspname = 'core');
BEGIN
    IF p_person_id IS NULL THEN
        RETURN NULL;
    END IF;
    v_lang := agent.fn_person_lang(p_person_id)->>'lang';

    FOR v_pkg IN
        SELECT r.package
        FROM core.package_registry r
        LEFT JOIN (SELECT split_part(k, ':', 1) AS pkg, min(i) AS pos
                   FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_order) = 'array' THEN p_order ELSE '[]'::jsonb END)
                        WITH ORDINALITY AS o(k, i)
                   GROUP BY 1) o ON o.pkg = r.package
        WHERE r.status = 'active' AND r.package <> 'core' AND r.package ~ '^[a-z][a-z0-9_]*$'
        ORDER BY COALESCE(o.pos, 100000), r.package
    LOOP
        v_fn := to_regprocedure(format('%I.fn_next_step_example(text)', v_pkg));
        CONTINUE WHEN v_fn IS NULL;
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_proc pr
            WHERE pr.oid = v_fn AND pr.proowner = v_owner AND pr.prosecdef
              AND EXISTS (SELECT 1 FROM unnest(pr.proconfig) c WHERE c LIKE 'search_path=%'));
        BEGIN
            EXECUTE format('SELECT %s($1)', v_fn::regproc) INTO v_key USING p_person_id;
        EXCEPTION WHEN OTHERS THEN
            v_key := NULL;
        END;
        CONTINUE WHEN v_key IS NULL OR left(v_key, length(v_pkg) + 1) <> v_pkg || '.';
        -- direkt aus dem Katalog: core.fn_ui_texts faellt auf den Key selbst zurueck, der kaeme sonst als Nutzertext an
        SELECT t.text INTO v_text FROM core.ui_texts t
        WHERE t.key = v_key AND t.lang IN (v_lang, 'en')
        ORDER BY (t.lang = v_lang) DESC LIMIT 1;
        CONTINUE WHEN v_text IS NULL OR v_text ~ '\{\w+\}';
        RETURN v_text;
    END LOOP;
    RETURN core.fn_ui_text('core.next_step.example_neutral', v_lang);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_get_next_step_example(text, jsonb) FROM public;
-- EXECUTE fuer core_ro (Menue-Fertigkarte, Mitglieder-Texte) erteilt packages/core/db/util/util_create_core_ro.sql.
