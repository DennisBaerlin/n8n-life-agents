-- tests/db/core/test_db_encoding.sql
-- Paritaet Test-DB <-> Prod-App-DB (UTF-8 ist Gesetz, provisioning/CLAUDE.md): Prod legt install_pg.sh mit
-- ENCODING UTF8 + LOCALE C.UTF-8 an; die db_test-DB (scripts/bootstrap_test_db.ps1) muss dasselbe sein, sonst sortieren
-- und vergleichen die Tests anders als Prod (en_US reiht „Ä" vor „Z", C.UTF-8 dahinter). Dieser Test faengt eine
-- Drift der Test-DB; den Installer selbst pruefen contract_lint 20, das Substrat (bootstrap_test_n8n) und doctor.
BEGIN;

DO $$
DECLARE
  v_enc  text;
  v_coll text;
  v_ctype text;
BEGIN
  SELECT pg_encoding_to_char(encoding), datcollate, datctype INTO v_enc, v_coll, v_ctype
    FROM pg_database WHERE datname = current_database();
  IF v_enc <> 'UTF8' THEN
    RAISE EXCEPTION 'FAIL db_encoding [Datenbank % ist %, erwartet UTF8 wie Prod]', current_database(), v_enc;
  END IF;
  IF v_coll <> 'C.UTF-8' OR v_ctype <> 'C.UTF-8' THEN
    RAISE EXCEPTION 'FAIL db_encoding [Locale collate=% ctype=%, erwartet C.UTF-8 wie Prod (install_pg.sh)]', v_coll, v_ctype;
  END IF;
  -- Die Eigenschaft, an der v0.4.0 scheiterte: ein Gedankenstrich (U+2013) ist kein Steuerzeichen.
  IF chr(8211) ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'FAIL db_encoding [U+2013 gilt als Steuerzeichen]';
  END IF;
  -- Code-Punkt-Sortierung wie Prod: „Ä" (U+00C4) nach „Z".
  IF NOT (chr(196) > 'Z') THEN
    RAISE EXCEPTION 'FAIL db_encoding [Sortierung weicht von Prod (C.UTF-8, Code-Punkt) ab]';
  END IF;
  RAISE NOTICE 'PASS db_encoding [UTF8 + C.UTF-8 wie Prod, Gedankenstrich kein Steuerzeichen]';
END $$;

ROLLBACK;
