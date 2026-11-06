-- tests/db/core/test_fn_should_notify.sql
-- Phase Notify (WS-1): geteilte Owner-Benachrichtigungs-Dedup-Schicht.
-- core.fn_should_notify(source, key, ttl) liefert true GDW der Latch jetzt ok->fired kippt
-- (Erst-Breach oder nach Re-Arm) und stempelt state='fired'/last_fired_at/expires_at.
-- Invarianten:
--   * Erst-Aufruf (keine Zeile)                 -> true,  state fired, expires NULL (kein TTL)
--   * zweiter Aufruf (fired, NULL-TTL)          -> false (NULL-TTL re-armt NIE automatisch)
--   * nach fn_notify_resolve                     -> wieder true (expliziter Re-Arm)
--   * TTL-Aufruf, innerhalb des Fensters         -> false; nach Ablauf -> true (auto Re-Arm)
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE r BOOLEAN; v_state TEXT; v_exp TIMESTAMPTZ;
BEGIN
  -- ---------- Erst-Aufruf ohne TTL -> feuert, Latch fired, expires NULL ----------
  r := core.fn_should_notify('test', 'k1');
  IF r IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [erst k1 muss true: %]', r; END IF;
  SELECT state, expires_at INTO v_state, v_exp FROM core.notification_state WHERE source='test' AND key='k1';
  IF v_state IS DISTINCT FROM 'fired' OR v_exp IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [k1 state=% exp=% (erwartet fired/NULL)]', v_state, v_exp; END IF;

  -- ---------- zweiter Aufruf (fired, NULL-TTL) -> still ----------
  r := core.fn_should_notify('test', 'k1');
  IF r IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [k1 re-still muss false: %]', r; END IF;

  -- ---------- expliziter Re-Arm -> wieder armed -> naechster feuert ----------
  PERFORM core.fn_notify_resolve('test', 'k1');
  SELECT state INTO v_state FROM core.notification_state WHERE source='test' AND key='k1';
  IF v_state IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL [k1 resolve muss ok: %]', v_state; END IF;
  r := core.fn_should_notify('test', 'k1');
  IF r IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [k1 nach resolve muss true: %]', r; END IF;

  -- ---------- TTL-Pfad: feuert + setzt expires; im Fenster still ----------
  r := core.fn_should_notify('test', 'k2', interval '1 hour');
  IF r IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [k2 erst muss true: %]', r; END IF;
  SELECT expires_at INTO v_exp FROM core.notification_state WHERE source='test' AND key='k2';
  IF v_exp IS NULL THEN RAISE EXCEPTION 'FAIL [k2 expires muss gesetzt sein]'; END IF;
  r := core.fn_should_notify('test', 'k2', interval '1 hour');
  IF r IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [k2 im Fenster muss false: %]', r; END IF;

  -- ---------- TTL kuenstlich abgelaufen -> auto Re-Arm -> feuert ----------
  UPDATE core.notification_state SET expires_at = now() - interval '1 minute' WHERE source='test' AND key='k2';
  r := core.fn_should_notify('test', 'k2', interval '1 hour');
  IF r IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [k2 nach TTL-Ablauf muss true (auto Re-Arm): %]', r; END IF;

  -- ---------- NULL-TTL fired re-armt NIE automatisch (k1 ist fired, expires NULL) ----------
  r := core.fn_should_notify('test', 'k1');
  IF r IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [k1 NULL-TTL fired muss still bleiben: %]', r; END IF;

  RAISE NOTICE 'PASS test_fn_should_notify [Erst-fire, NULL-TTL-Latch, expliziter Re-Arm, TTL-Fenster + auto Re-Arm]';
END $$;

-- ---------- Strukturelle Invarianten core.notification_state (DB ist Gesetz) ----------
DO $$
BEGIN
  -- PK (source, key): genau eine Latch-Zeile je (source,key)
  INSERT INTO core.notification_state (source, key, state) VALUES ('struct', 'k', 'fired');
  BEGIN
    INSERT INTO core.notification_state (source, key, state) VALUES ('struct', 'k', 'ok');
    RAISE EXCEPTION 'FAIL [pk]: doppelter (source,key) akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [notification_state PK (source,key)]';
  END;
  -- state-CHECK ok|fired
  BEGIN
    INSERT INTO core.notification_state (source, key, state) VALUES ('struct', 'k2', 'bogus');
    RAISE EXCEPTION 'FAIL [state check]: ungueltiger state akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [notification_state state-CHECK ok|fired]';
  END;
END $$;

ROLLBACK;
