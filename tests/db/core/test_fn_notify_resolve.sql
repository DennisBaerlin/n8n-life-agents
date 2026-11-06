-- tests/db/core/test_fn_notify_resolve.sql
-- Phase Notify (WS-1): expliziter Re-Arm der geteilten Dedup-Schicht.
-- core.fn_notify_resolve(source, key) setzt state='ok', expires_at=NULL (No-op ohne Zeile).
BEGIN;

DO $$
DECLARE v_state TEXT; v_exp TIMESTAMPTZ;
BEGIN
  -- ---------- resolve auf nicht-existente Zeile -> No-op, kein Fehler, kein INSERT ----------
  PERFORM core.fn_notify_resolve('test', 'ghost');
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source='test' AND key='ghost') THEN
    RAISE EXCEPTION 'FAIL [resolve darf keine Zeile anlegen]'; END IF;

  -- ---------- fired (mit TTL) anlegen, dann resolve -> ok + expires NULL ----------
  PERFORM core.fn_should_notify('test', 'r1', interval '1 hour');
  PERFORM core.fn_notify_resolve('test', 'r1');
  SELECT state, expires_at INTO v_state, v_exp FROM core.notification_state WHERE source='test' AND key='r1';
  IF v_state IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL [resolve muss ok setzen: %]', v_state; END IF;
  IF v_exp IS NOT NULL THEN RAISE EXCEPTION 'FAIL [resolve muss expires_at NULL setzen: %]', v_exp; END IF;

  RAISE NOTICE 'PASS test_fn_notify_resolve [No-op ohne Zeile; setzt ok + expires NULL]';
END $$;

ROLLBACK;
