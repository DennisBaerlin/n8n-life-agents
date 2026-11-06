-- tests/db/core/test_fn_fmt_date.sql
-- core.fn_fmt_date(date, lang): Datum fuer SQL-gerenderte Dokumente (Notfallmappe) im Muster der Sprachliste
--   (core.ui_languages.date_pattern). Gleiche Ausgabe wie Fmt-DateJs mit Intl (de 31.12.2026, en-GB 31/12/2026,
--   ko 2026. 12. 31.); fehlendes Muster / unbekannte Sprache -> ISO; NULL -> NULL.
BEGIN;

DO $$
BEGIN
  UPDATE core.ui_languages SET date_pattern = CASE code WHEN 'de' THEN 'DD.MM.YYYY' WHEN 'en' THEN 'DD/MM/YYYY'
                                                        WHEN 'ko' THEN 'YYYY. MM. DD.' END
   WHERE code IN ('de', 'en', 'ko');
  IF core.fn_fmt_date('2026-12-31', 'de') IS DISTINCT FROM '31.12.2026' THEN
    RAISE EXCEPTION 'FAIL fmt_date [de: %]', core.fn_fmt_date('2026-12-31', 'de'); END IF;
  IF core.fn_fmt_date('2026-12-31', 'en') IS DISTINCT FROM '31/12/2026' THEN
    RAISE EXCEPTION 'FAIL fmt_date [en: %]', core.fn_fmt_date('2026-12-31', 'en'); END IF;
  IF core.fn_fmt_date('2026-01-05', 'ko') IS DISTINCT FROM '2026. 01. 05.' THEN
    RAISE EXCEPTION 'FAIL fmt_date [ko: %]', core.fn_fmt_date('2026-01-05', 'ko'); END IF;
  IF core.fn_fmt_date('2026-12-31', 'fr') IS DISTINCT FROM '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL fmt_date [unbekannte Sprache -> ISO: %]', core.fn_fmt_date('2026-12-31', 'fr'); END IF;
  UPDATE core.ui_languages SET date_pattern = NULL WHERE code = 'de';
  IF core.fn_fmt_date('2026-12-31', 'de') IS DISTINCT FROM '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL fmt_date [kein Muster -> ISO: %]', core.fn_fmt_date('2026-12-31', 'de'); END IF;
  IF core.fn_fmt_date(NULL, 'de') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fmt_date [NULL]'; END IF;
  -- Backstop: ein Muster ist nur aus Datums-Platzhaltern + Trennzeichen (kein Freitext, der to_char-Codes enthaelt)
  BEGIN
    UPDATE core.ui_languages SET date_pattern = 'Stand: DD' WHERE code = 'en';
    RAISE EXCEPTION 'FAIL fmt_date [CHECK laesst Freitext-Muster zu]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS fn_fmt_date [de/en/ko wie Intl, ISO-Fallback, NULL, CHECK]';
END $$;

ROLLBACK;
