-- ============================================================
-- core.fn_fmt_money (read-only, Geldbetrag fuer SQL-gerenderte Texte)
--   Zwei Nachkommastellen, Tausender- und Dezimalzeichen nach der Sprache, Waehrung wie Intl im locale der Sprache
--   (core.ui_languages.locale): de-* "1.234,56 €", sonst "€1,234.56"; andere Waehrungen als Code ("1.234,56 USD" bzw.
--   "USD 1,234.56"). Bei uns anders: PostgreSQL hat kein Intl; Workflows formatieren per Intl (Render-Bibliothek), nur
--   Texte, die eine DB-fn fertig baut (Knopf-Handler der Callback-Registry), nutzen diese fn. NULL -> NULL.
--   Tests: tests/db/core/test_fn_fmt_money.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_fmt_money(p_amount numeric, p_currency text, p_lang text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_amount IS NULL THEN NULL
                WHEN de THEN replace(replace(replace(num, ',', '#'), '.', ','), '#', '.') || ' ' || sym
                ELSE CASE WHEN cur = 'EUR' THEN sgn || '€' || ltrim(num, '-') ELSE cur || ' ' || num END END
    FROM (SELECT to_char(round(p_amount, 2), 'FM999,999,999,990.00') AS num,
                 CASE WHEN p_amount < 0 THEN '-' ELSE '' END AS sgn,
                 upper(COALESCE(NULLIF(btrim(p_currency), ''), 'EUR')) AS cur,
                 CASE WHEN upper(COALESCE(NULLIF(btrim(p_currency), ''), 'EUR')) = 'EUR' THEN '€'
                      ELSE upper(btrim(p_currency)) END AS sym,
                 COALESCE((SELECT l.locale FROM core.ui_languages l WHERE l.code = p_lang), 'en') ILIKE 'de%' AS de) x;
$$;
