-- tests/db/core/test_fn_dispatch_followup.sql
-- Folge-Bindung nach einem Knopf-Tipp (2026-10-28): agent.fn_set_dispatch_followup(p) setzt je Chat den Agenten, der
-- gerade per Knopf geantwortet hat (last write wins); agent.fn_take_dispatch_followup(p) liest UND loescht (einmalig),
-- nur innerhalb von 30 Minuten (TTL beim Lesen).
BEGIN;

DO $$
DECLARE v jsonb; a text;
BEGIN
  DELETE FROM agent.dispatch_followup;

  -- (1) setzen + einmalig nehmen
  v := agent.fn_set_dispatch_followup('{"chat_id":"222","agent":"agent.finance_advisor"}');
  IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 set]: %', v; END IF;
  a := agent.fn_take_dispatch_followup('{"chat_id":"222"}');
  IF a IS DISTINCT FROM 'agent.finance_advisor' THEN RAISE EXCEPTION 'FAIL [1 take]: %', a; END IF;
  IF agent.fn_take_dispatch_followup('{"chat_id":"222"}') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1 einmalig]'; END IF;

  -- (2) last write wins
  PERFORM agent.fn_set_dispatch_followup('{"chat_id":"222","agent":"agent.finance"}');
  PERFORM agent.fn_set_dispatch_followup('{"chat_id":"222","agent":"agent.guide"}');
  IF (SELECT count(*) FROM agent.dispatch_followup WHERE chat_id = '222') <> 1 THEN RAISE EXCEPTION 'FAIL [2 eine Zeile]'; END IF;
  IF agent.fn_take_dispatch_followup('{"chat_id":"222"}') IS DISTINCT FROM 'agent.guide' THEN RAISE EXCEPTION 'FAIL [2 last write]'; END IF;

  -- (3) abgelaufen (> 30 Min) -> NULL und weg
  PERFORM agent.fn_set_dispatch_followup('{"chat_id":"222","agent":"agent.finance"}');
  UPDATE agent.dispatch_followup SET set_at = now() - interval '31 minutes' WHERE chat_id = '222';
  IF agent.fn_take_dispatch_followup('{"chat_id":"222"}') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 TTL]'; END IF;
  IF EXISTS (SELECT 1 FROM agent.dispatch_followup WHERE chat_id = '222') THEN RAISE EXCEPTION 'FAIL [3 TTL nicht geloescht]'; END IF;

  -- (4) ungueltige Eingaben: nie RAISE, nichts gesetzt
  v := agent.fn_set_dispatch_followup('{"chat_id":"-100123","agent":"agent.finance"}');
  IF (v->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4 Gruppe]: %', v; END IF;
  v := agent.fn_set_dispatch_followup('{"chat_id":"222","agent":"drop table"}');
  IF (v->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4 agent]: %', v; END IF;
  IF agent.fn_take_dispatch_followup('{"chat_id":""}') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4 leer]'; END IF;

  RAISE NOTICE 'PASS test_fn_dispatch_followup (einmalig, last write wins, TTL 30 Min, Guards)';
END $$;

ROLLBACK;
