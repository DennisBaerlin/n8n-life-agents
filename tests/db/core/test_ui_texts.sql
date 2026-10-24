-- tests/db/core/test_ui_texts.sql
-- Textkatalog fester Nutzertexte (core.ui_languages + core.ui_texts) und die Lookup-fns:
--   * Sprachliste: core:V027 legt de/en/ko an (Manifest-Upsert ueberschreibt Name/Locale/Reihenfolge)
--   * Constraints: Code-Form, Key-Form, Key-Prefix == package, leerer Text, unbekannte Sprache (FK)
--   * core.fn_ui_text: Treffer, Fallback lang -> en -> Key selbst, {platzhalter}-Ersetzung
--   * core.fn_ui_texts: Bundle (Key -> Text) mit derselben Fallback-Kette
-- Fixture-Keys (core.test_*), keine Echt-Wortlaute. BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r JSONB;
  t TEXT;
BEGIN
  -- ---------- Sprachliste aus V027 ----------
  IF (SELECT count(*) FROM core.ui_languages WHERE code IN ('de','en','ko')) <> 3 THEN
    RAISE EXCEPTION 'FAIL ui_texts [de/en/ko fehlen in core.ui_languages]'; END IF;
  IF (SELECT locale FROM core.ui_languages WHERE code = 'ko') IS DISTINCT FROM 'ko-KR' THEN
    RAISE EXCEPTION 'FAIL ui_texts [ko ohne Locale ko-KR]'; END IF;

  -- ---------- Constraints ----------
  BEGIN
    INSERT INTO core.ui_languages (code, name, locale, ord) VALUES ('DEU', 'x', 'x', 9);
    RAISE EXCEPTION 'FAIL ui_texts [3-Buchstaben-Code akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('finance.test_x', 'de', 'x', 'core');
    RAISE EXCEPTION 'FAIL ui_texts [Key-Prefix <> package akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('core', 'de', 'x', 'core');
    RAISE EXCEPTION 'FAIL ui_texts [Key ohne Bereich akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('core.test_empty', 'de', '', 'core');
    RAISE EXCEPTION 'FAIL ui_texts [leerer Text akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('core.test_fk', 'xx', 'x', 'core');
    RAISE EXCEPTION 'FAIL ui_texts [unbekannte Sprache akzeptiert]';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- ---------- Fixture ----------
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.test_greet', 'de', 'Hallo {name}, {name}!', 'core'),
    ('core.test_greet', 'en', 'Hello {name}', 'core'),
    ('core.test_greet', 'ko', '{name} 님 안녕하세요', 'core'),
    ('core.test_only_en', 'en', 'english only', 'core');

  -- ---------- fn_ui_text ----------
  t := core.fn_ui_text('core.test_greet', 'ko', '{"name":"Mina"}');
  IF t IS DISTINCT FROM 'Mina 님 안녕하세요' THEN
    RAISE EXCEPTION 'FAIL ui_texts [ko-Treffer/Platzhalter: %]', t; END IF;
  t := core.fn_ui_text('core.test_greet', 'de', '{"name":"Mina"}');
  IF t IS DISTINCT FROM 'Hallo Mina, Mina!' THEN
    RAISE EXCEPTION 'FAIL ui_texts [Platzhalter nicht ueberall ersetzt: %]', t; END IF;
  t := core.fn_ui_text('core.test_only_en', 'ko');
  IF t IS DISTINCT FROM 'english only' THEN
    RAISE EXCEPTION 'FAIL ui_texts [Fallback auf en fehlt: %]', t; END IF;
  t := core.fn_ui_text('core.test_missing', 'de');
  IF t IS DISTINCT FROM 'core.test_missing' THEN
    RAISE EXCEPTION 'FAIL ui_texts [fehlender Key nicht als Key zurueck: %]', t; END IF;
  t := core.fn_ui_text('core.test_greet', NULL, '{"name":"X"}');
  IF t IS DISTINCT FROM 'Hello X' THEN
    RAISE EXCEPTION 'FAIL ui_texts [lang NULL faellt nicht auf en: %]', t; END IF;
  -- ein Wert, der selbst wie ein Platzhalter aussieht, wird NICHT erneut ersetzt (ein Durchlauf, wie der JS-Renderer)
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('core.test_two', 'de', '{name}={language}', 'core');
  t := core.fn_ui_text('core.test_two', 'de', '{"name":"{language}","language":"한국어"}');
  IF t IS DISTINCT FROM '{language}=한국어' THEN
    RAISE EXCEPTION 'FAIL ui_texts [Platzhalter im Wert erneut ersetzt: %]', t; END IF;
  t := core.fn_ui_text('core.test_two', 'de', '{"language":"x"}');
  IF t IS DISTINCT FROM '{name}=x' THEN
    RAISE EXCEPTION 'FAIL ui_texts [fehlender Parameter muss als {name} stehen bleiben: %]', t; END IF;

  -- ---------- fn_ui_texts (Bundle) ----------
  r := core.fn_ui_texts('ko', ARRAY['core.test_greet', 'core.test_only_en', 'core.test_missing']);
  IF r->>'core.test_greet' IS DISTINCT FROM '{name} 님 안녕하세요'
     OR r->>'core.test_only_en' IS DISTINCT FROM 'english only'
     OR r->>'core.test_missing' IS DISTINCT FROM 'core.test_missing' THEN
    RAISE EXCEPTION 'FAIL ui_texts [Bundle falsch: %]', r; END IF;
  r := core.fn_ui_texts('de', ARRAY[]::text[]);
  IF r IS DISTINCT FROM '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL ui_texts [leeres Bundle nicht {}: %]', r; END IF;

  RAISE NOTICE 'PASS ui_texts [Sprachliste, Constraints, Fallback lang->en->Key, Platzhalter, Bundle]';
END $$;

ROLLBACK;
