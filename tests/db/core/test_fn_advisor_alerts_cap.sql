-- tests/db/core/test_fn_advisor_alerts_cap.sql
-- core.fn_advisor_alerts_cap: Grenze je Nachricht (3 beim ersten Lauf, sonst 5), Reihenfolge priority DESC + Eingang,
-- gekuerzte Punkte verlieren ihre frischen Merker und kommen am naechsten Lauf wieder.
BEGIN;

CREATE OR REPLACE FUNCTION finance.fn__test_cap_review(p_domain text, p_person_id text, p_obs jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('alerts', COALESCE(NULLIF(current_setting('test.alerts', true), ''), '[]')::jsonb, 'digest', '{}'::jsonb);
$$;
INSERT INTO core.advisors (domain, plan_context, review_fn, package) VALUES ('__cap__', 'x', 'finance.fn__test_cap_review', '__cap__');

DO $$
DECLARE
  r jsonb; c jsonb;
  v_four text := '[{"metric_key":"a","priority":10},{"metric_key":"b","priority":100},{"metric_key":"c","priority":50},{"metric_key":"d","priority":90}]';
  v_six  text := '[{"metric_key":"m1","priority":60},{"metric_key":"m2","priority":60},{"metric_key":"m3","priority":60},{"metric_key":"m4","priority":60},{"metric_key":"m5","priority":60},{"metric_key":"m6","priority":60}]';
BEGIN
  -- erster Lauf: 3 hoechste, Rest ungemerkt
  PERFORM set_config('test.alerts', v_four, true);
  r := core.fn_advisor_review_evaluate('__cap__');
  c := core.fn_advisor_alerts_cap(r->'alerts', (r->>'first_run')::boolean);
  IF (SELECT array_agg(e->>'metric_key' ORDER BY o) FROM jsonb_array_elements(c->'alerts') WITH ORDINALITY t(e, o)) <> ARRAY['b','d','c']
     OR (c->>'more_count')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [first_run -> 3 hoechste, more 1]: %', c; END IF;
  IF (SELECT state FROM core.notification_state WHERE source = 'advisor:__cap__' AND key = 'a') <> 'ok' THEN
    RAISE EXCEPTION 'FAIL [gekuerzter Merker wieder ok]'; END IF;
  IF (SELECT count(*) FROM core.notification_state WHERE source = 'advisor:__cap__' AND key IN ('b','c','d') AND state = 'fired') <> 3 THEN
    RAISE EXCEPTION 'FAIL [gesendete bleiben fired]'; END IF;
  IF c->'alerts'->0 ? '_latched' THEN RAISE EXCEPTION 'FAIL [_latched bleibt intern]'; END IF;

  -- naechster Lauf liefert nur den gekuerzten neu
  r := core.fn_advisor_review_evaluate('__cap__');
  IF jsonb_array_length(r->'alerts') <> 1 OR r->'alerts'->0->>'metric_key' <> 'a' OR (r->>'first_run')::boolean THEN
    RAISE EXCEPTION 'FAIL [gekuerzter Punkt kommt neu, first_run=false]: %', r; END IF;

  -- sechs ohne first_run -> 5, gleiche Prioritaet behaelt die Reihenfolge
  c := core.fn_advisor_alerts_cap(v_six::jsonb, false);
  IF (SELECT array_agg(e->>'metric_key' ORDER BY o) FROM jsonb_array_elements(c->'alerts') WITH ORDINALITY t(e, o)) <> ARRAY['m1','m2','m3','m4','m5']
     OR (c->>'more_count')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [6 -> 5, stabil]: %', c; END IF;

  -- Mengen-Alarm: nur die frischen Elemente zurueck, das alte bleibt fired
  DELETE FROM core.notification_state WHERE source = 'advisor:__cap__';
  PERFORM core.fn_should_notify('advisor:__cap__', '__first_run__');
  PERFORM core.fn_should_notify('advisor:__cap__', 's#old');
  PERFORM set_config('test.alerts', '[{"metric_key":"t1","priority":100},{"metric_key":"t2","priority":100},{"metric_key":"t3","priority":100},{"metric_key":"t4","priority":100},{"metric_key":"t5","priority":100},{"metric_key":"s","priority":1,"latch_keys":["old","new"]}]', true);
  r := core.fn_advisor_review_evaluate('__cap__');
  c := core.fn_advisor_alerts_cap(r->'alerts', false);
  IF (c->>'more_count')::int <> 1 THEN RAISE EXCEPTION 'FAIL [latch more]: %', c; END IF;
  IF (SELECT state FROM core.notification_state WHERE source = 'advisor:__cap__' AND key = 's#new') <> 'ok'
     OR (SELECT state FROM core.notification_state WHERE source = 'advisor:__cap__' AND key = 's#old') <> 'fired' THEN
    RAISE EXCEPTION 'FAIL [nur frische Elemente zurueck]'; END IF;

  -- zwei Domains gemeinsam sortiert, ohne priority zaehlt 50
  c := core.fn_advisor_alerts_cap('[{"metric_key":"x1","domain":"a","priority":40},{"metric_key":"x2","domain":"b"},{"metric_key":"x3","domain":"a","priority":60}]'::jsonb, false);
  IF (SELECT array_agg(e->>'metric_key' ORDER BY o) FROM jsonb_array_elements(c->'alerts') WITH ORDINALITY t(e, o)) <> ARRAY['x3','x2','x1'] THEN
    RAISE EXCEPTION 'FAIL [gemeinsam sortiert, Default 50]: %', c; END IF;

  -- leer
  c := core.fn_advisor_alerts_cap('[]'::jsonb, true);
  IF jsonb_array_length(c->'alerts') <> 0 OR (c->>'more_count')::int <> 0 THEN RAISE EXCEPTION 'FAIL [leer]: %', c; END IF;

  RAISE NOTICE 'PASS fn_advisor_alerts_cap';
END $$;
ROLLBACK;
