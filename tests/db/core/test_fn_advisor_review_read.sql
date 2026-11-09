-- tests/db/core/test_fn_advisor_review_read.sql
-- core.fn_advisor_review_read: voller Lagebericht ohne Merker.
BEGIN;

CREATE OR REPLACE FUNCTION finance.fn__test_read_review(p_domain text, p_person_id text, p_obs jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('alerts', '[{"metric_key":"a"}]'::jsonb, 'digest', jsonb_build_object('lines', '[]'::jsonb, 'person', p_person_id));
$$;
INSERT INTO core.advisors (domain, plan_context, review_fn, package) VALUES ('__rd__', 'x', 'finance.fn__test_read_review', '__rd__');

DO $$
DECLARE r jsonb; v_before bigint;
BEGIN
  SELECT count(*) INTO v_before FROM core.notification_state;
  r := core.fn_advisor_review_read('__rd__', 'erika');
  IF NOT (r->>'ok')::boolean OR jsonb_array_length(r->'alerts') <> 1 OR r->'digest'->>'person' <> 'erika' THEN
    RAISE EXCEPTION 'FAIL [liefert Alarme und Digest]: %', r; END IF;
  IF (SELECT count(*) FROM core.notification_state) <> v_before THEN RAISE EXCEPTION 'FAIL [schreibt nie]'; END IF;

  r := core.fn_advisor_review_read('__nope__');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [unbekannte Domain -> ok:false]: %', r; END IF;
  RAISE NOTICE 'PASS fn_advisor_review_read';
END $$;
ROLLBACK;
