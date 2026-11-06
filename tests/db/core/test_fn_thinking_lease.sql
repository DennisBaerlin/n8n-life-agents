-- tests/db/core/test_fn_thinking_lease.sql
-- "Denkt nach"-Schalter (agent.thinking_lease): fn_create_thinking_lease / fn_claim_thinking_draft /
-- fn_delete_thinking_lease + das Draft-Fenster in fn_create_hitl_pending.
-- Invarianten:
--   * create: je Chat EIN Schalter (Telegram zeigt je Chat eine Blase) -> loescht andere Schalter des Chats (auch
--     liegengebliebene abgebrochener Laeufe) und Abgelaufene; expires_at = now() + ttl; Upsert je execution
--   * claim: keine/abgelaufene/fehlende execution -> stop (auch bei offener Karte); offene Karte im Chat -> pause
--     + expires_at >= now()+5min; sonst show + drafting_until ~ clock_timestamp()+1s. Fremde/freigegebene/abgelaufene
--     Karten pausieren nicht.
--   * delete: per execution_id ODER chat_id (alle Schalter des Chats); wait_for_draft wartet ein laufendes Fenster ab
--     (<= 1 s), sonst nie; idempotent, leer = no-op
--   * fn_create_hitl_pending wartet ein laufendes Draft-Fenster des Chats ab (<= 1 s) -> kein Draft nach der Karte
--   * nicht-numerische chat_id (Test-Sentinel) -> {ok:false}; fehlende Pflichtfelder (Bau-Fehler) -> RAISE
-- BEGIN...ROLLBACK -> kein Residual-State. now() ist in der Transaktion konstant, clock_timestamp() nicht.
BEGIN;

DO $$
DECLARE r JSONB; v_exp timestamptz; v_t0 timestamptz; v_ms numeric;
BEGIN
  DELETE FROM agent.thinking_lease WHERE chat_id IN (900201, 900202);
  DELETE FROM agent.hitl_pending   WHERE chat_id IN (900201, 900202);

  -- ---------- create: Zeile, expires_at = now() + ttl, Upsert ----------
  r := agent.fn_create_thinking_lease('{"chat_id":"900201","execution_id":"t1","ttl_minutes":15}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL create [nicht ok: %]', r; END IF;
  v_exp := (r->>'expires_at')::timestamptz;
  IF v_exp IS DISTINCT FROM now() + interval '15 minutes' THEN
    RAISE EXCEPTION 'FAIL create [expires_at % != now()+15min]', v_exp; END IF;
  r := agent.fn_create_thinking_lease('{"chat_id":"900201","execution_id":"t1","ttl_minutes":15}'::jsonb);
  IF (SELECT count(*) FROM agent.thinking_lease WHERE execution_id = 't1') <> 1 THEN
    RAISE EXCEPTION 'FAIL create [Upsert legt zweite Zeile an]'; END IF;
  RAISE NOTICE 'PASS create [Zeile, expires_at, Upsert]';

  -- ---------- claim show: drafting_until = Fenster ab jetzt ----------
  r := agent.fn_claim_thinking_draft('{"execution_id":"t1"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'show' THEN RAISE EXCEPTION 'FAIL claim [erwartet show: %]', r; END IF;
  IF (SELECT drafting_until FROM agent.thinking_lease WHERE execution_id = 't1')
       NOT BETWEEN clock_timestamp() + interval '0.5 seconds' AND clock_timestamp() + interval '1 second' THEN
    RAISE EXCEPTION 'FAIL claim [drafting_until nicht ~ jetzt+1s]'; END IF;
  RAISE NOTICE 'PASS claim show [drafting_until gesetzt]';

  -- ---------- claim pause: offene Karte im Chat, verlaengert den Schalter ----------
  INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, expires_at)
       VALUES (900201, 'card1', false, now() + interval '10 minutes');
  UPDATE agent.thinking_lease SET expires_at = now() + interval '1 minute' WHERE execution_id = 't1';
  r := agent.fn_claim_thinking_draft('{"execution_id":"t1"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'pause' THEN RAISE EXCEPTION 'FAIL pause [erwartet pause bei offener Karte: %]', r; END IF;
  IF (SELECT expires_at FROM agent.thinking_lease WHERE execution_id = 't1') IS DISTINCT FROM now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'FAIL pause [expires_at nicht auf now()+5min verlaengert]'; END IF;
  UPDATE agent.thinking_lease SET expires_at = now() + interval '9 minutes' WHERE execution_id = 't1';
  r := agent.fn_claim_thinking_draft('{"execution_id":"t1"}'::jsonb);
  IF (SELECT expires_at FROM agent.thinking_lease WHERE execution_id = 't1') IS DISTINCT FROM now() + interval '9 minutes' THEN
    RAISE EXCEPTION 'FAIL pause [laengere Restlaufzeit gekuerzt]'; END IF;
  RAISE NOTICE 'PASS claim pause [offene Karte (auch own_card=false), Verlaengerung nur nach oben]';

  -- ---------- freigegebene / abgelaufene / fremde Karte pausiert nicht ----------
  UPDATE agent.hitl_pending SET released_at = now() WHERE execution_id = 'card1';
  r := agent.fn_claim_thinking_draft('{"execution_id":"t1"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'show' THEN RAISE EXCEPTION 'FAIL pause [freigegebene Karte pausiert: %]', r; END IF;
  UPDATE agent.hitl_pending SET released_at = NULL, opened_at = now() - interval '20 minutes',
                                expires_at = now() - interval '1 minute' WHERE execution_id = 'card1';
  r := agent.fn_claim_thinking_draft('{"execution_id":"t1"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'show' THEN RAISE EXCEPTION 'FAIL pause [abgelaufene Karte pausiert: %]', r; END IF;
  INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES (900202, 'card2', now() + interval '10 minutes');
  r := agent.fn_claim_thinking_draft('{"execution_id":"t1"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'show' THEN RAISE EXCEPTION 'FAIL pause [Karte im fremden Chat pausiert: %]', r; END IF;
  RAISE NOTICE 'PASS claim [freigegebene, abgelaufene, fremde Karte -> show]';

  -- ---------- claim stop: unbekannte/fehlende execution, abgelaufener Schalter (Vorrang vor pause) ----------
  r := agent.fn_claim_thinking_draft('{"execution_id":"nix"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'stop' THEN RAISE EXCEPTION 'FAIL stop [unbekannte execution: %]', r; END IF;
  r := agent.fn_claim_thinking_draft('{"execution_id":""}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'stop' THEN RAISE EXCEPTION 'FAIL stop [leere execution: %]', r; END IF;
  r := agent.fn_create_thinking_lease('{"chat_id":"900202","execution_id":"t2","ttl_minutes":15}'::jsonb);
  UPDATE agent.thinking_lease SET opened_at = now() - interval '20 minutes', expires_at = now() - interval '1 second'
   WHERE execution_id = 't2';
  r := agent.fn_claim_thinking_draft('{"execution_id":"t2"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'stop' THEN
    RAISE EXCEPTION 'FAIL stop [abgelaufener Schalter mit offener Karte nicht stop: %]', r; END IF;
  RAISE NOTICE 'PASS claim stop [unbekannt, leer, abgelaufen hat Vorrang vor pause]';

  -- ---------- create: ein Schalter je Chat, raeumt Abgelaufene weg ----------
  r := agent.fn_create_thinking_lease('{"chat_id":"900201","execution_id":"t3","ttl_minutes":15}'::jsonb);
  IF EXISTS (SELECT 1 FROM agent.thinking_lease WHERE execution_id IN ('t1', 't2')) THEN
    RAISE EXCEPTION 'FAIL create [alter Schalter des Chats bzw. abgelaufener nicht weggeraeumt]'; END IF;
  r := agent.fn_claim_thinking_draft('{"execution_id":"t1"}'::jsonb);
  IF r->>'state' IS DISTINCT FROM 'stop' THEN RAISE EXCEPTION 'FAIL create [verdraengte Schleife laeuft weiter: %]', r; END IF;
  RAISE NOTICE 'PASS create [ein Schalter je Chat, verdraengte Schleife stoppt, Abgelaufene weg]';

  -- ---------- delete: wartet ein laufendes Fenster ab ----------
  UPDATE agent.thinking_lease SET drafting_until = clock_timestamp() + interval '400 milliseconds' WHERE execution_id = 't3';
  v_t0 := clock_timestamp();
  r := agent.fn_delete_thinking_lease('{"execution_id":"t3","wait_for_draft":true}'::jsonb);
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  IF (r->>'removed')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL delete [nicht entfernt: %]', r; END IF;
  IF v_ms < 300 OR v_ms > 1400 THEN RAISE EXCEPTION 'FAIL delete [Fenster nicht abgewartet: % ms]', v_ms; END IF;
  RAISE NOTICE 'PASS delete [wartet laufendes Fenster ab: % ms]', round(v_ms);

  -- ---------- delete: kein Warten ohne Flag / bei abgelaufenem Fenster ----------
  r := agent.fn_create_thinking_lease('{"chat_id":"900201","execution_id":"t4","ttl_minutes":15}'::jsonb);
  UPDATE agent.thinking_lease SET drafting_until = clock_timestamp() + interval '800 milliseconds' WHERE execution_id = 't4';
  v_t0 := clock_timestamp();
  r := agent.fn_delete_thinking_lease('{"execution_id":"t4"}'::jsonb);
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  IF (r->>'removed')::boolean IS DISTINCT FROM true OR v_ms > 200 THEN
    RAISE EXCEPTION 'FAIL delete [ohne wait_for_draft gewartet/nicht entfernt: % ms, %]', v_ms, r; END IF;
  r := agent.fn_create_thinking_lease('{"chat_id":"900201","execution_id":"t5","ttl_minutes":15}'::jsonb);
  UPDATE agent.thinking_lease SET opened_at = now() - interval '1 minute', drafting_until = now() - interval '1 second'
   WHERE execution_id = 't5';
  v_t0 := clock_timestamp();
  r := agent.fn_delete_thinking_lease('{"execution_id":"t5","wait_for_draft":true}'::jsonb);
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  IF (r->>'removed')::boolean IS DISTINCT FROM true OR v_ms > 200 THEN
    RAISE EXCEPTION 'FAIL delete [vergangenes Fenster abgewartet: % ms]', v_ms; END IF;
  RAISE NOTICE 'PASS delete [kein Warten ohne Flag oder bei vergangenem Fenster]';

  -- ---------- delete per chat_id: alle Schalter des Chats, fremde Chats bleiben ----------
  r := agent.fn_create_thinking_lease('{"chat_id":"900201","execution_id":"t6","ttl_minutes":15}'::jsonb);
  r := agent.fn_create_thinking_lease('{"chat_id":"900202","execution_id":"t7","ttl_minutes":15}'::jsonb);
  r := agent.fn_delete_thinking_lease('{"chat_id":"900201"}'::jsonb);
  IF (r->>'removed')::boolean IS DISTINCT FROM true OR EXISTS (SELECT 1 FROM agent.thinking_lease WHERE execution_id = 't6') THEN
    RAISE EXCEPTION 'FAIL delete [per chat_id nicht entfernt: %]', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.thinking_lease WHERE execution_id = 't7') THEN
    RAISE EXCEPTION 'FAIL delete [fremder Chat mit geloescht]'; END IF;
  RAISE NOTICE 'PASS delete [per chat_id, fremder Chat bleibt]';

  -- ---------- delete: idempotent, leer/unbekannt/Sentinel = no-op ----------
  r := agent.fn_delete_thinking_lease('{"execution_id":"t6","wait_for_draft":true}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'removed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete [Idempotenz: %]', r; END IF;
  r := agent.fn_delete_thinking_lease('{"execution_id":"","chat_id":""}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'removed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete [leer kein no-op: %]', r; END IF;
  r := agent.fn_delete_thinking_lease('{"chat_id":"test_e2e"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'removed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete [Sentinel-Chat kein no-op: %]', r; END IF;
  RAISE NOTICE 'PASS delete [idempotent, leer/Sentinel = no-op]';

  -- ---------- fn_create_hitl_pending wartet ein laufendes Draft-Fenster des Chats ab ----------
  UPDATE agent.thinking_lease SET drafting_until = clock_timestamp() + interval '400 milliseconds' WHERE execution_id = 't7';
  v_t0 := clock_timestamp();
  r := agent.fn_create_hitl_pending('{"chat_id":"900202","execution_id":"card3","ttl_minutes":16}'::jsonb);
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR v_ms < 300 OR v_ms > 1400 THEN
    RAISE EXCEPTION 'FAIL hitl [Karte wartet das Draft-Fenster nicht ab: % ms, %]', v_ms, r; END IF;
  v_t0 := clock_timestamp();
  r := agent.fn_create_hitl_pending('{"chat_id":"900201","execution_id":"card4","ttl_minutes":16}'::jsonb);
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  IF v_ms > 200 THEN RAISE EXCEPTION 'FAIL hitl [Karte ohne Draft-Fenster wartet: % ms]', v_ms; END IF;
  RAISE NOTICE 'PASS hitl [Karte wartet laufendes Draft-Fenster ab, sonst sofort]';

  -- ---------- Sentinel / Pflichtfelder ----------
  r := agent.fn_create_thinking_lease('{"chat_id":"test_e2e","execution_id":"t8","ttl_minutes":15}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL sentinel [nicht-numerisch akzeptiert: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.thinking_lease WHERE execution_id = 't8') THEN
    RAISE EXCEPTION 'FAIL sentinel [Zeile fuer Sentinel angelegt]'; END IF;
  BEGIN
    PERFORM agent.fn_create_thinking_lease('{"chat_id":"900201","ttl_minutes":15}'::jsonb);
    RAISE EXCEPTION 'FAIL required [fehlende execution_id akzeptiert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM agent.fn_create_thinking_lease('{"chat_id":"900201","execution_id":"t9"}'::jsonb);
    RAISE EXCEPTION 'FAIL required [fehlende ttl_minutes akzeptiert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS [Sentinel ohne Zeile, Pflichtfelder RAISE]';

  RAISE NOTICE 'PASS fn_create/claim/delete thinking_lease [alle Invarianten]';
END $$;

ROLLBACK;
