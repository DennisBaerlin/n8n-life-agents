-- tests/db/core/test_fn_notify_reconcile.sql
-- Phase Notify (WS-1): Bulk-Re-Arm fuer level-triggered Producer (Advisor).
-- core.fn_notify_reconcile(source, keys[]) loescht alle Zeilen der source, deren key NICHT in keys liegt
-- (= wieder im Band / stale -> re-armed); leeres keys -> alle source-Zeilen weg; fremde sources unberuehrt.
BEGIN;

DO $$
DECLARE v_cnt INT;
BEGIN
  -- drei advisor-Latches + ein knock-Latch anlegen
  PERFORM core.fn_should_notify('advisor:finance', 'a');
  PERFORM core.fn_should_notify('advisor:finance', 'b');
  PERFORM core.fn_should_notify('advisor:finance', 'c');
  PERFORM core.fn_should_notify('knock', '999');

  -- ---------- Reconcile mit {a,c}: b geraeumt (re-armed), a+c bleiben, fremde source knock unberuehrt ----------
  PERFORM core.fn_notify_reconcile('advisor:finance', ARRAY['a','c']);
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source='advisor:finance' AND key='b') THEN
    RAISE EXCEPTION 'FAIL [GC]: stale key b nicht geraeumt'; END IF;
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:finance';
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [GC]: a+c sollen bleiben (count=% erwartet 2)', v_cnt; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source='knock' AND key='999') THEN
    RAISE EXCEPTION 'FAIL [GC]: fremde source knock faelschlich geloescht'; END IF;
  RAISE NOTICE 'PASS [reconcile: stale key weg, aktive bleiben, fremde source unberuehrt]';

  -- ---------- leeres key-Set: alle advisor:finance-Zeilen weg (alles re-armed) ----------
  PERFORM core.fn_notify_reconcile('advisor:finance', ARRAY[]::text[]);
  SELECT count(*) INTO v_cnt FROM core.notification_state WHERE source='advisor:finance';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [empty]: leeres Set muss alle source-Zeilen loeschen (count=%)', v_cnt; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source='knock' AND key='999') THEN
    RAISE EXCEPTION 'FAIL [empty]: leeres Set darf fremde source nicht treffen'; END IF;
  RAISE NOTICE 'PASS [reconcile: leeres key-Set raeumt die ganze source (Re-Arm aller), fremde source bleibt]';

  -- ---------- key im aktuellen Set bleibt (kein faelschliches Loeschen) ----------
  PERFORM core.fn_should_notify('advisor:finance', 'x');
  PERFORM core.fn_notify_reconcile('advisor:finance', ARRAY['x']);
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source='advisor:finance' AND key='x') THEN
    RAISE EXCEPTION 'FAIL [keep]: key x im aktuellen Set faelschlich geloescht'; END IF;
  RAISE NOTICE 'PASS [reconcile: key im aktuellen Set bleibt]';
END $$;

ROLLBACK;
