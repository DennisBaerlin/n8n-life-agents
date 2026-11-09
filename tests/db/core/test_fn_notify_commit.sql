-- tests/db/core/test_fn_notify_commit.sql
-- core.fn_notify_commit: Frist weg nur bei state='fired'.
BEGIN;
DO $$
BEGIN
  PERFORM core.fn_should_notify('t_commit', 'a', interval '30 minutes');
  PERFORM core.fn_notify_commit('t_commit', 'a');
  IF (SELECT expires_at FROM core.notification_state WHERE source = 't_commit' AND key = 'a') IS NOT NULL THEN RAISE EXCEPTION 'FAIL Frist'; END IF;
  IF core.fn_should_notify('t_commit', 'a', interval '30 minutes') THEN RAISE EXCEPTION 'FAIL bleibt fest'; END IF;
  INSERT INTO core.notification_state (source, key, state, expires_at) VALUES ('t_commit', 'b', 'ok', now());
  PERFORM core.fn_notify_commit('t_commit', 'b');
  IF (SELECT expires_at FROM core.notification_state WHERE source = 't_commit' AND key = 'b') IS NULL THEN RAISE EXCEPTION 'FAIL nur fired'; END IF;
END $$;
ROLLBACK;
