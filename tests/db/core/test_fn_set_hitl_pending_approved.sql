-- tests/db/core/test_fn_set_hitl_pending_approved.sql
-- agent.fn_set_hitl_pending_approved(p): das Gate markiert an seinen Erfolgs-Ausgaengen ALLE Zeilen seiner
--   Execution als endgueltig bestaetigt (Vier-Augen: Mitglieds- und Owner-Zeile derselben Gate-Execution).
--   * andere Executions bleiben unberuehrt; Default der Spalte = NULL (nicht bestaetigt)
--   * leere/fehlende execution_id -> {ok:false}, kein Write
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  DELETE FROM agent.hitl_pending WHERE chat_id IN (501, 502);
  INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, expires_at) VALUES
    (501, 'ex-a', true,  now() + interval '1 hour'),
    (502, 'ex-a', false, now() + interval '1 hour'),
    (501, 'ex-b', true,  now() + interval '1 hour');

  IF EXISTS (SELECT 1 FROM agent.hitl_pending WHERE chat_id IN (501, 502) AND approved IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL set_hitl_pending_approved [Default nicht NULL]'; END IF;

  r := agent.fn_set_hitl_pending_approved(jsonb_build_object('execution_id', 'ex-a'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'rows')::int <> 2 THEN
    RAISE EXCEPTION 'FAIL set_hitl_pending_approved [Rueckgabe: %]', r; END IF;
  IF (SELECT count(*) FROM agent.hitl_pending WHERE execution_id = 'ex-a' AND approved IS TRUE) <> 2 THEN
    RAISE EXCEPTION 'FAIL set_hitl_pending_approved [nicht alle Zeilen der Execution]'; END IF;
  IF (SELECT approved FROM agent.hitl_pending WHERE execution_id = 'ex-b') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL set_hitl_pending_approved [fremde Execution beruehrt]'; END IF;

  r := agent.fn_set_hitl_pending_approved(jsonb_build_object('execution_id', ''));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_hitl_pending_approved [leere execution_id: %]', r; END IF;

  RAISE NOTICE 'PASS fn_set_hitl_pending_approved [alle Zeilen der Execution, fremde unberuehrt, leere id abgelehnt]';
END $$;

ROLLBACK;
