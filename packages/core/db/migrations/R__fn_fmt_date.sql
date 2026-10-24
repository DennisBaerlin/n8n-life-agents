-- ============================================================
-- core.fn_fmt_date (read-only, Datum fuer SQL-gerenderte Dokumente)
--   Formatiert ein Datum im Muster der Sprache (core.ui_languages.date_pattern, Quelle: Core-Manifest
--   languages.list[].date_pattern). Die Muster liefern dieselbe Ausgabe wie Fmt-DateJs mit Intl im Workflow
--   (de 31.12.2026, en-GB 31/12/2026, ko 2026. 12. 31.). Bei uns anders: PostgreSQL hat kein Intl; Workflows
--   formatieren immer per Intl, nur ganze Dokumente aus SQL (Notfallmappe) nutzen diese fn.
--   Fehlt das Muster oder die Sprache -> ISO 'YYYY-MM-DD'. NULL -> NULL.
--   Kein Grant: einzige Aufrufer sind SECURITY-DEFINER-fns (estate.fn_render_emergency_binder) bzw. das
--   Haupt-Credential; ein Paket-Rollen-Aufrufer braeuchte erst ein Fenster.
--   Tests: tests/db/core/test_fn_fmt_date.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_fmt_date(p_date date, p_lang text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_date IS NULL THEN NULL
                ELSE to_char(p_date, COALESCE(
                    (SELECT l.date_pattern FROM core.ui_languages l WHERE l.code = p_lang), 'YYYY-MM-DD'))
           END;
$$;
