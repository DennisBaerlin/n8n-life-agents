-- tests/db/career/test_fn_market_scope_key.sql
-- career.fn_market_scope_key: EINE Quelle des Markt-Cache-Schluessel-Formats (Write==Read).
-- Format <kind>:<slug(primary)>:<slug(secondary)>; Slug lower/trim + Nicht-Alphanum->'-' (am Rand gestrippt).
BEGIN;
DO $$
BEGIN
  -- salary: KldB + Region bleiben (Ziffern), kind-Praefix
  IF career.fn_market_scope_key('salary','43412','1') <> 'salary:43412:1' THEN
    RAISE EXCEPTION 'FAIL [salary key]: %', career.fn_market_scope_key('salary','43412','1'); END IF;

  -- postings: Rolle + Ort sluggifiziert
  IF career.fn_market_scope_key('postings','Scrum Master','Hamburg') <> 'postings:scrum-master:hamburg' THEN
    RAISE EXCEPTION 'FAIL [postings slug]: %', career.fn_market_scope_key('postings','Scrum Master','Hamburg'); END IF;

  -- Sonderzeichen am Rand gestrippt, Mehrfach-Trenner kollabiert ('C++  Developer!' -> 'c-developer')
  IF career.fn_market_scope_key('postings','C++  Developer!','Bad Oeynhausen') <> 'postings:c-developer:bad-oeynhausen' THEN
    RAISE EXCEPTION 'FAIL [slug edge]: %', career.fn_market_scope_key('postings','C++  Developer!','Bad Oeynhausen'); END IF;

  -- Determinismus (gleiche Eingabe -> gleicher Key; sonst nie ein Trend-/Gap-Match)
  IF career.fn_market_scope_key('salary','43412','1') <> career.fn_market_scope_key('salary','43412','1') THEN
    RAISE EXCEPTION 'FAIL [determinism]'; END IF;

  -- leeres secondary -> leerer Slug-Teil (Ort fehlt)
  IF career.fn_market_scope_key('postings','Scrum Master','') <> 'postings:scrum-master:' THEN
    RAISE EXCEPTION 'FAIL [empty secondary]: %', career.fn_market_scope_key('postings','Scrum Master',''); END IF;

  -- NULL -> leere Slugs, kein Crash
  IF career.fn_market_scope_key('salary',NULL,NULL) <> 'salary::' THEN
    RAISE EXCEPTION 'FAIL [null -> empty]: %', career.fn_market_scope_key('salary',NULL,NULL); END IF;

  RAISE NOTICE 'PASS test_fn_market_scope_key';
END $$;
ROLLBACK;
