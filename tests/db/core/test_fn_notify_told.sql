-- tests/db/core/test_fn_notify_told.sql
-- core.fn_notify_told: Lese-Sicht "wurde das schon gemeldet und gilt noch".
BEGIN;
DO $$
BEGIN
  IF core.fn_notify_told('__t__', 'none') THEN RAISE EXCEPTION 'FAIL [keine Zeile -> false]'; END IF;

  INSERT INTO core.notification_state (source, key, state) VALUES ('__t__', 'armed', 'ok');
  IF core.fn_notify_told('__t__', 'armed') THEN RAISE EXCEPTION 'FAIL [ok -> false]'; END IF;

  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('__t__', 'forever', 'fired', now());
  IF NOT core.fn_notify_told('__t__', 'forever') THEN RAISE EXCEPTION 'FAIL [fired ohne Ablauf -> true]'; END IF;

  INSERT INTO core.notification_state (source, key, state, last_fired_at, expires_at)
    VALUES ('__t__', 'future', 'fired', now(), now() + interval '1 hour');
  IF NOT core.fn_notify_told('__t__', 'future') THEN RAISE EXCEPTION 'FAIL [Ablauf in der Zukunft -> true]'; END IF;

  INSERT INTO core.notification_state (source, key, state, last_fired_at, expires_at)
    VALUES ('__t__', 'past', 'fired', now() - interval '2 hours', now() - interval '1 hour');
  IF core.fn_notify_told('__t__', 'past') THEN RAISE EXCEPTION 'FAIL [abgelaufen -> false]'; END IF;

  RAISE NOTICE 'PASS fn_notify_told';
END $$;
ROLLBACK;
