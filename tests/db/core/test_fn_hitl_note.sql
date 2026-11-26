-- tests/db/core/test_fn_hitl_note.sql
-- Text bei offener Bestaetigungs-Karte (Zwischenschritt bis Anmerkung auf allen Karten):
--   * agent.fn_stash_hitl_note merkt den Text an den offenen eigenen Zeilen des Chats (nicht an freigegebenen, fremden,
--     abgelaufenen), haengt weitere Texte an, kappt bei 1000 Zeichen;
--   * agent.fn_take_hitl_note gibt ihn je Execution einmal zurueck und leert ihn; bei approved nur leeren; nie RAISE.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r jsonb;
BEGIN
  DELETE FROM agent.hitl_pending WHERE chat_id IN (111, 222);
  INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, opened_at, released_at, expires_at) VALUES
    (111, 'ex-open', true,  now(), NULL,  now() + interval '10 minutes'),
    (111, 'ex-rel',  true,  now(), now(), now() + interval '10 minutes'),
    (111, 'ex-other', false, now(), NULL, now() + interval '10 minutes'),
    (222, 'ex-222',  true,  now(), NULL,  now() + interval '10 minutes');

  r := agent.fn_stash_hitl_note('{"chat_id":"111","text":"  "}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 leerer Text]: %', r; END IF;
  r := agent.fn_stash_hitl_note('{"chat_id":"111","text":"Lieber 50 Euro"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'stored')::int <> 1 THEN RAISE EXCEPTION 'FAIL [1 stash]: %', r; END IF;
  r := agent.fn_stash_hitl_note(jsonb_build_object('chat_id','111','text', repeat('x', 1200)));
  IF (SELECT length(note) FROM agent.hitl_pending WHERE execution_id = 'ex-open') <> 1000
     OR (SELECT note FROM agent.hitl_pending WHERE execution_id = 'ex-open') NOT LIKE 'Lieber 50 Euro' || E'\n' || 'x%' THEN
    RAISE EXCEPTION 'FAIL [1 anhaengen + kappen]'; END IF;
  IF EXISTS (SELECT 1 FROM agent.hitl_pending WHERE execution_id IN ('ex-rel', 'ex-other', 'ex-222') AND note IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL [1 nur offene eigene Zeilen dieses Chats]'; END IF;
  RAISE NOTICE 'PASS [1 stash]';

  r := agent.fn_take_hitl_note('{"execution_id":"ex-open","approved":false}');
  IF r->>'note' NOT LIKE 'Lieber 50 Euro%' THEN RAISE EXCEPTION 'FAIL [2 take]: %', r; END IF;
  r := agent.fn_take_hitl_note('{"execution_id":"ex-open","approved":false}');
  IF r->>'note' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 nur einmal]: %', r; END IF;
  PERFORM agent.fn_stash_hitl_note('{"chat_id":"111","text":"anders"}');
  r := agent.fn_take_hitl_note('{"execution_id":"ex-open","approved":true}');
  IF r->>'note' IS NOT NULL OR (SELECT note FROM agent.hitl_pending WHERE execution_id = 'ex-open') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2 approved leert nur]: %', r; END IF;
  r := agent.fn_take_hitl_note('{"execution_id":"gibt-es-nicht"}');
  IF r IS NULL OR r->>'note' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 unbekannt]: %', r; END IF;
  r := agent.fn_take_hitl_note(NULL);
  IF r IS NULL THEN RAISE EXCEPTION 'FAIL [2 NULL wirft nicht]'; END IF;
  RAISE NOTICE 'PASS [2 take]';
END $$;

ROLLBACK;
