-- tests/db/core/test_fn_is_blocked.sql
-- WS-5d Owner-Sperrliste (agent.access_blocks): fn_block_knocker / fn_unblock_knocker / fn_is_blocked.
-- Invarianten:
--   * block legt eine Sperr-Zeile an -> fn_is_blocked=true; idempotent (zweites block = no-op, eine Zeile)
--   * block einer NIE-geklopften uid erzeugt KEINE knock-Latch-Zeile (core.notification_state ehrlich)
--   * unblock entfernt die Zeile -> fn_is_blocked=false; was_blocked-Flag korrekt; idempotent
--   * fn_is_blocked(NULL) -> false; nicht-numerische uid -> {ok:false}; reason gespeichert
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE r JSONB;
BEGIN
  -- ---------- block: legt Sperre an, fn_is_blocked=true ----------
  r := agent.fn_block_knocker('{"telegram_user_id":900001,"reason":"spam"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'blocked')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL block [Sperre nicht angelegt: %]', r; END IF;
  IF agent.fn_is_blocked(900001) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL is_blocked [900001 nach block nicht gesperrt]'; END IF;
  IF (SELECT reason FROM agent.access_blocks WHERE telegram_user_id = 900001) IS DISTINCT FROM 'spam' THEN
    RAISE EXCEPTION 'FAIL block [reason nicht gespeichert]'; END IF;

  -- ---------- block: idempotent (zweites block -> eine Zeile, kein Fehler) ----------
  r := agent.fn_block_knocker('{"telegram_user_id":900001}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL block [zweites block nicht ok: %]', r; END IF;
  IF (SELECT count(*) FROM agent.access_blocks WHERE telegram_user_id = 900001) <> 1 THEN
    RAISE EXCEPTION 'FAIL block [zweites block legte zweite Zeile an]'; END IF;

  -- ---------- block einer NIE-geklopften uid erzeugt KEINE knock-Latch-Zeile (Kern-Eigenschaft) ----------
  -- 900001 wurde nur gesperrt (kein Knock) -> core.notification_state darf KEINE knock-Zeile dafuer haben.
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'knock' AND key = '900001') THEN
    RAISE EXCEPTION 'FAIL block [Sperre fabrizierte eine synthetische knock-Latch-Zeile]'; END IF;
  RAISE NOTICE 'PASS block [Sperre angelegt, idempotent, reason, KEINE synthetische knock-Latch-Zeile]';

  -- ---------- unblock: entfernt die Zeile, was_blocked=true, fn_is_blocked=false ----------
  r := agent.fn_unblock_knocker('{"telegram_user_id":900001}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'was_blocked')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL unblock [Sperre nicht aufgehoben / was_blocked falsch: %]', r; END IF;
  IF agent.fn_is_blocked(900001) THEN RAISE EXCEPTION 'FAIL unblock [900001 nach unblock noch gesperrt]'; END IF;

  -- ---------- unblock: idempotent (nicht-gesperrte uid -> was_blocked=false) ----------
  r := agent.fn_unblock_knocker('{"telegram_user_id":900001}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'was_blocked')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL unblock [idempotenz / was_blocked auf nicht-gesperrt: %]', r; END IF;
  RAISE NOTICE 'PASS unblock [Sperre aufgehoben, was_blocked korrekt, idempotent]';

  -- ---------- is_blocked(NULL) -> false ----------
  IF agent.fn_is_blocked(NULL) THEN RAISE EXCEPTION 'FAIL is_blocked [NULL-uid als gesperrt gewertet]'; END IF;

  -- ---------- block/unblock: Pflichtfeld + nicht-numerisch -> {ok:false} ----------
  r := agent.fn_block_knocker('{}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL block [fehlende uid akzeptiert]'; END IF;
  r := agent.fn_block_knocker('{"telegram_user_id":"abc"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL block [nicht-numerische uid akzeptiert]'; END IF;
  RAISE NOTICE 'PASS [is_blocked(NULL)=false; fehlende/nicht-numerische uid abgelehnt]';

  RAISE NOTICE 'PASS fn_is_blocked/fn_block_knocker/fn_unblock_knocker [alle Invarianten]';
END $$;

ROLLBACK;
