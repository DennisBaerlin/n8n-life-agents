-- tests/db/core/test_fn_register_knock.sql
-- Owner-Notify-Anti-Spam (Phase 4, Phase Notify migriert): fn_register_knock drosselt die Owner-
-- Benachrichtigung ueber unbekannte Absender ueber die GETEILTE core.notification_state (source='knock').
-- Invarianten (Cooldown-Vertrag unveraendert; nur die State-Quelle wechselte von agent.knock_log):
--   * erster Knock einer Identitaet            -> notify=true (Latch-Zeile fired)
--   * sofortiger zweiter Knock (im Cooldown)   -> notify=false (kein Spam)
--   * Knock nach Ablauf des Cooldown-Fensters  -> notify=true wieder
--   * expliziter Cooldown-Parameter wirkt
--   * NULL-uid (Testpfad ohne from.id)         -> notify=false (kein Write/Spam)
--   * gesperrte uid                            -> notify=false, blocked=true, KEINE Latch-Zeile
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE r JSONB;
BEGIN
  -- ---------- erster Knock -> benachrichtigen ----------
  r := agent.fn_register_knock(424242);
  IF (r->>'notify')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL knock [erster Knock muss notify=true: %]', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source='knock' AND key='424242' AND state='fired') THEN
    RAISE EXCEPTION 'FAIL knock [Latch-Zeile knock/424242 (fired) fehlt nach erstem Knock]'; END IF;

  -- ---------- sofortiger zweiter Knock -> gedrosselt ----------
  r := agent.fn_register_knock(424242);
  IF (r->>'notify')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL knock [zweiter Knock im Cooldown muss notify=false: %]', r; END IF;

  -- ---------- Cooldown kuenstlich ablaufen lassen (expires_at in die Vergangenheit) -> wieder notify ----------
  -- (NOW() ist tx-konstant -> die TTL-Wirkung ueber kuenstliches Altern des expires_at pruefen.)
  UPDATE core.notification_state SET expires_at = NOW() - INTERVAL '1 minute' WHERE source='knock' AND key='424242';
  r := agent.fn_register_knock(424242);   -- Default-Cooldown 1h
  IF (r->>'notify')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL knock [nach Cooldown muss notify=true: %]', r; END IF;

  -- ---------- expliziter Cooldown-Parameter wirkt ----------
  UPDATE core.notification_state SET expires_at = NOW() - INTERVAL '1 minute' WHERE source='knock' AND key='424242';
  r := agent.fn_register_knock(424242, INTERVAL '10 minutes');   -- abgelaufen -> notify
  IF (r->>'notify')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL knock [10min abgelaufen muss notify=true: %]', r; END IF;
  r := agent.fn_register_knock(424242, INTERVAL '10 minutes');   -- frisch benachrichtigt -> still
  IF (r->>'notify')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL knock [frisch benachrichtigt, cooldown 10min muss notify=false: %]', r; END IF;

  -- ---------- NULL-uid (Testpfad) -> kein notify, keine Latch-Zeile ----------
  r := agent.fn_register_knock(NULL);
  IF (r->>'notify')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL knock [NULL-uid muss notify=false: %]', r; END IF;

  -- ---------- WS-5d: gesperrte uid -> notify=false, blocked=true UND KEINE Latch-Zeile ----------
  PERFORM agent.fn_block_knocker('{"telegram_user_id":555555}'::jsonb);
  r := agent.fn_register_knock(555555);
  IF (r->>'notify')::boolean IS DISTINCT FROM false OR (r->>'blocked')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL knock [gesperrte uid muss notify=false,blocked=true: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source='knock' AND key='555555') THEN
    RAISE EXCEPTION 'FAIL knock [gesperrte uid legte eine Latch-Zeile an]'; END IF;

  RAISE NOTICE 'PASS fn_register_knock [Erst-Knock notify, Cooldown-Drossel, Ablauf, custom cooldown, NULL-uid, Sperre]';
END $$;

ROLLBACK;
