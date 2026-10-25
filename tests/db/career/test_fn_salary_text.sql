-- tests/db/career/test_fn_salary_text.sql
-- career.fn_salary_annual(amount, period) + career.fn_salary_text(amount, period, basis): ein Gehalt wird mit seiner
--   Einheit gespeichert (Rohwert) und erst beim Anzeigen aufs Jahr gerechnet (Monat x 12). brutto/netto wird nie
--   umgerechnet (ohne Steuerrechnung unmoeglich); eine fehlende Einheit (Bestand) wird offen gezeigt, nie angenommen.
BEGIN;

DO $$
BEGIN
  IF career.fn_salary_annual(4000, 'month') IS DISTINCT FROM 48000 THEN RAISE EXCEPTION 'FAIL [annual month]'; END IF;
  IF career.fn_salary_annual(75000, 'year') IS DISTINCT FROM 75000 THEN RAISE EXCEPTION 'FAIL [annual year]'; END IF;
  IF career.fn_salary_annual(75000, NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [annual ohne Einheit -> NULL]'; END IF;

  IF career.fn_salary_text(4000, 'month', 'net') IS DISTINCT FROM '4000 € netto/Monat (≈ 48000 € netto/Jahr)' THEN
    RAISE EXCEPTION 'FAIL [Text Monat netto: %]', career.fn_salary_text(4000, 'month', 'net'); END IF;
  IF career.fn_salary_text(75000, 'year', 'gross') IS DISTINCT FROM '75000 € brutto/Jahr' THEN
    RAISE EXCEPTION 'FAIL [Text Jahr brutto: %]', career.fn_salary_text(75000, 'year', 'gross'); END IF;
  IF career.fn_salary_text(3500.5, 'month', NULL) IS DISTINCT FROM '3500.5 €/Monat (≈ 42006 €/Jahr; brutto/netto offen)' THEN
    RAISE EXCEPTION 'FAIL [Text ohne Basis: %]', career.fn_salary_text(3500.5, 'month', NULL); END IF;
  IF career.fn_salary_text(60000, NULL, NULL) IS DISTINCT FROM '60000 € (Einheit offen)' THEN
    RAISE EXCEPTION 'FAIL [Text Bestand ohne Einheit: %]', career.fn_salary_text(60000, NULL, NULL); END IF;
  IF career.fn_salary_text(NULL, 'year', 'gross') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [ohne Betrag -> NULL]'; END IF;
  RAISE NOTICE 'PASS fn_salary_annual/fn_salary_text [Monat x 12, Basis bleibt, fehlende Einheit offen]';
END $$;

ROLLBACK;
