-- tests/db/core/test_fn_resolve_date.sql
-- core.fn_resolve_date(text, today): relative Zeitangabe ("-3 days", "in 3 weeks", "last friday") -> Datum; die DB
--   rechnet, das LLM uebersetzt nur. core.fn_resolve_fact_dates(jsonb, today): dasselbe rekursiv fuer Fakten-Keys
--   *_date / since, Genauigkeit folgt der Angabe (Jahre -> YYYY, Monate -> YYYY-MM, sonst Tag).
--   Fester Bezugstag 2026-10-25 (ein Sonntag), damit jede Assertion deterministisch ist.
BEGIN;

DO $$
DECLARE
  t date := '2026-10-25';
BEGIN
  -- ---------- absolut + Schluesselwoerter ----------
  IF core.fn_resolve_date('2026-10-01', t) IS DISTINCT FROM '2026-10-01'::date THEN RAISE EXCEPTION 'FAIL [ISO]'; END IF;
  IF core.fn_resolve_date('2024-02-30', t) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [ungueltiges ISO -> NULL]'; END IF;
  IF core.fn_resolve_date('today', t) IS DISTINCT FROM t THEN RAISE EXCEPTION 'FAIL [today]'; END IF;
  IF core.fn_resolve_date(' Yesterday ', t) IS DISTINCT FROM '2026-10-24'::date THEN RAISE EXCEPTION 'FAIL [yesterday trim/case]'; END IF;
  IF core.fn_resolve_date('tomorrow', t) IS DISTINCT FROM '2026-10-26'::date THEN RAISE EXCEPTION 'FAIL [tomorrow]'; END IF;

  -- ---------- Offsets ----------
  IF core.fn_resolve_date('-3 days', t) IS DISTINCT FROM '2026-10-22'::date THEN RAISE EXCEPTION 'FAIL [-3 days]'; END IF;
  IF core.fn_resolve_date('3 days ago', t) IS DISTINCT FROM '2026-10-22'::date THEN RAISE EXCEPTION 'FAIL [3 days ago]'; END IF;
  IF core.fn_resolve_date('+1 day', t) IS DISTINCT FROM '2026-10-26'::date THEN RAISE EXCEPTION 'FAIL [+1 day]'; END IF;
  IF core.fn_resolve_date('in 3 weeks', t) IS DISTINCT FROM '2026-11-15'::date THEN RAISE EXCEPTION 'FAIL [in 3 weeks]'; END IF;
  IF core.fn_resolve_date('+6 Months', t) IS DISTINCT FROM '2027-04-25'::date THEN RAISE EXCEPTION 'FAIL [+6 months]'; END IF;
  IF core.fn_resolve_date('-12 years', t) IS DISTINCT FROM '2014-10-25'::date THEN RAISE EXCEPTION 'FAIL [-12 years]'; END IF;
  IF core.fn_resolve_date('+1 month', '2026-01-31') IS DISTINCT FROM '2026-02-28'::date THEN
    RAISE EXCEPTION 'FAIL [Monatsende-Clamp: %]', core.fn_resolve_date('+1 month', '2026-01-31'); END IF;

  -- ---------- Wochentage: strikt danach/davor (1..7 Tage), t ist ein Sonntag ----------
  IF core.fn_resolve_date('next monday', t) IS DISTINCT FROM '2026-10-26'::date THEN RAISE EXCEPTION 'FAIL [next monday]'; END IF;
  IF core.fn_resolve_date('last friday', t) IS DISTINCT FROM '2026-10-23'::date THEN RAISE EXCEPTION 'FAIL [last friday]'; END IF;
  IF core.fn_resolve_date('next sunday', t) IS DISTINCT FROM '2026-11-01'::date THEN RAISE EXCEPTION 'FAIL [next sunday = +7]'; END IF;
  IF core.fn_resolve_date('last sunday', t) IS DISTINCT FROM '2026-10-18'::date THEN RAISE EXCEPTION 'FAIL [last sunday = -7]'; END IF;

  -- ---------- Ablehnung (NULL -> der Aufrufer antwortet {ok:false}) ----------
  IF core.fn_resolve_date('-3 days ago', t) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Vorzeichen + ago]'; END IF;
  IF core.fn_resolve_date('3 days', t) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [ohne Richtung]'; END IF;
  IF core.fn_resolve_date('vor drei Tagen', t) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Freitext]'; END IF;
  IF core.fn_resolve_date('', t) IS NOT NULL OR core.fn_resolve_date(NULL, t) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [leer/NULL]'; END IF;

  -- ---------- Default-Bezugstag = core.fn_today() ----------
  IF core.fn_resolve_date('today') IS DISTINCT FROM core.fn_today() THEN RAISE EXCEPTION 'FAIL [Default fn_today]'; END IF;

  RAISE NOTICE 'PASS fn_resolve_date [ISO, Schluesselwoerter, Offsets, Clamp, Wochentage, Ablehnung, Default]';
END $$;

DO $$
DECLARE
  t date := '2026-10-25';
  r jsonb;
BEGIN
  r := core.fn_resolve_fact_dates(jsonb_build_object(
         'career_start_date', '-12 years',
         'target_date', '+6 months',
         'event_date', '3 days ago',
         'last_job_change_date', 'last monday',
         'birth_date', '-5 years',
         'kept_date', '2012-09',
         'year_date', '2012',
         'bad_date', 'gestern',
         'num_date', 5,
         'note', '-3 days',
         'skills', jsonb_build_array(jsonb_build_object('name', 'SQL', 'since', 'in 2 years'),
                                     jsonb_build_object('name', 'Go', 'since', '2019'))), t);
  IF r->>'career_start_date' IS DISTINCT FROM '2014' THEN RAISE EXCEPTION 'FAIL [Jahre -> YYYY: %]', r->>'career_start_date'; END IF;
  IF r->>'target_date' IS DISTINCT FROM '2027-04' THEN RAISE EXCEPTION 'FAIL [Monate -> YYYY-MM: %]', r->>'target_date'; END IF;
  IF r->>'event_date' IS DISTINCT FROM '2026-10-22' THEN RAISE EXCEPTION 'FAIL [Tage -> Tag: %]', r->>'event_date'; END IF;
  IF r->>'last_job_change_date' IS DISTINCT FROM '2026-10-19' THEN RAISE EXCEPTION 'FAIL [Wochentag -> Tag: %]', r->>'last_job_change_date'; END IF;
  -- kein erfundener Geburtstag: "mein Sohn ist 5" wird ein Jahr, das der family-Validator als Geburtsdatum ablehnt
  IF r->>'birth_date' IS DISTINCT FROM '2021' THEN RAISE EXCEPTION 'FAIL [birth_date nur Jahr: %]', r->>'birth_date'; END IF;
  IF r->>'kept_date' IS DISTINCT FROM '2012-09' OR r->>'year_date' IS DISTINCT FROM '2012' THEN
    RAISE EXCEPTION 'FAIL [absolute Teil-Daten unveraendert]'; END IF;
  IF r->>'bad_date' IS DISTINCT FROM 'gestern' THEN RAISE EXCEPTION 'FAIL [unaufloesbar bleibt roh]'; END IF;
  IF r->'num_date' IS DISTINCT FROM '5'::jsonb THEN RAISE EXCEPTION 'FAIL [Nicht-String unveraendert]'; END IF;
  IF r->>'note' IS DISTINCT FROM '-3 days' THEN RAISE EXCEPTION 'FAIL [fremder Key unveraendert]'; END IF;
  IF r#>>'{skills,0,since}' IS DISTINCT FROM '2028' OR r#>>'{skills,1,since}' IS DISTINCT FROM '2019' THEN
    RAISE EXCEPTION 'FAIL [verschachtelt skills[].since: %]', r->'skills'; END IF;
  IF r#>>'{skills,0,name}' IS DISTINCT FROM 'SQL' THEN RAISE EXCEPTION 'FAIL [Array-Reihenfolge/Inhalt]'; END IF;
  IF core.fn_resolve_fact_dates(NULL, t) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [NULL]'; END IF;
  RAISE NOTICE 'PASS fn_resolve_fact_dates [Genauigkeit je Einheit, absolut/unaufloesbar/fremd unveraendert, rekursiv]';
END $$;

ROLLBACK;
