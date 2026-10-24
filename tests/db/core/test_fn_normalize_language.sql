-- tests/db/core/test_fn_normalize_language.sql
-- agent.fn_normalize_language(text): freie Sprach-Angaben -> Code aus core.ui_languages oder NULL.
--   * Code direkt (auch Gross/Leerzeichen), Region abgeschnitten (ko-KR, de_DE)
--   * Aliase aus core.ui_languages.aliases (deutsch/German/Koreanisch/한국어/English)
--   * nicht unterstuetzt / Muell / NULL -> NULL
-- agent.fn_normalize_person_languages(persons jsonb): dieselbe Normalisierung je Person fuer Restore-Bundles;
--   Owner ohne abbildbare Sprache -> 'de', Mitglied ohne -> Key entfernt.
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  IF agent.fn_normalize_language('ko') IS DISTINCT FROM 'ko'
     OR agent.fn_normalize_language(' DE ') IS DISTINCT FROM 'de'
     OR agent.fn_normalize_language('ko-KR') IS DISTINCT FROM 'ko'
     OR agent.fn_normalize_language('de_DE') IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL normalize_language [Code/Region]'; END IF;
  IF agent.fn_normalize_language('Deutsch') IS DISTINCT FROM 'de'
     OR agent.fn_normalize_language('German') IS DISTINCT FROM 'de'
     OR agent.fn_normalize_language('Koreanisch') IS DISTINCT FROM 'ko'
     OR agent.fn_normalize_language('한국어') IS DISTINCT FROM 'ko'
     OR agent.fn_normalize_language('English') IS DISTINCT FROM 'en' THEN
    RAISE EXCEPTION 'FAIL normalize_language [Aliase]'; END IF;
  IF agent.fn_normalize_language('fr') IS NOT NULL
     OR agent.fn_normalize_language('Deutsch/Koreanisch') IS NOT NULL
     OR agent.fn_normalize_language('') IS NOT NULL
     OR agent.fn_normalize_language(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL normalize_language [nicht unterstuetzt muss NULL sein]'; END IF;

  r := agent.fn_normalize_person_languages(jsonb_build_array(
         jsonb_build_object('person_id','o','role','owner','language','Deutsch'),
         jsonb_build_object('person_id','p','role','partner','language','Korean'),
         jsonb_build_object('person_id','c','role','child','language','fr'),
         jsonb_build_object('person_id','o2','role','owner')));
  IF r->0->>'language' IS DISTINCT FROM 'de'
     OR r->1->>'language' IS DISTINCT FROM 'ko'
     OR (r->2) ? 'language'
     OR r->3->>'language' IS DISTINCT FROM 'de'
     OR jsonb_array_length(r) <> 4 THEN
    RAISE EXCEPTION 'FAIL normalize_person_languages [%]', r; END IF;
  IF agent.fn_normalize_person_languages(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL normalize_person_languages [NULL nicht durchgereicht]'; END IF;

  RAISE NOTICE 'PASS fn_normalize_language [Code, Region, Aliase, unbekannt->NULL, Personen-Liste]';
END $$;

ROLLBACK;
