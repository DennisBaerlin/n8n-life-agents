-- tests/db/core/test_fn_claim_persona_sticker.sql
-- agent.fn_claim_persona_sticker(p): waehlt hoechstens EINEN Sticker je Antwort und setzt die Bremse.
--   * Prioritaet yay > top > hmm > hallo; Set = Persona des Absenders (neutral = Roboter-Set 'neutral')
--   * top nur bei ENDGUELTIG bestaetigter Karte DIESES Laufs (approved, opened_at >= Nachrichtenzeit) + FRAME
--   * hmm nur Datei + FRAME; hallo nur reiner Gruss ohne Werkzeug-Aufruf; nie bei NOFRAME
--   * Bremse je Person (persona_sticker:<pid>, Default 4 h); yay + Persona-Wahl umgehen sie, setzen sie aber
--   * Aus-Schalter core.config persona.stickers_enabled; unbekannter Absender -> kein Sticker
BEGIN;

DO $$
DECLARE
  r      JSONB;
  v_now  TEXT := now()::text;   -- Laufbeginn (DB-Zeit wie opened_at/last_fired_at)
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'claim_persona_sticker fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','P','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111),
              jsonb_build_object('person_id','mina','first_name','Mina','last_name','P','role','partner',
                                 'birth_date','1985-01-01','language','ko','telegram_user_id',222,'persona','butler')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;
  DELETE FROM core.notification_state WHERE source = 'persona_sticker';
  DELETE FROM agent.hitl_pending WHERE chat_id IN (111, 222);

  -- ---------- hallo: reiner Gruss, kein Werkzeug, neutral = Roboter-Set ----------
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '111', 'text', 'Hallo!', 'tool_called', false,
         'has_file', false, 'signal', '', 'run_started_at', v_now));
  IF r->>'sticker' IS DISTINCT FROM 'neutral_hallo' THEN
    RAISE EXCEPTION 'FAIL claim_persona_sticker [neutral hallo: %]', r; END IF;

  -- ---------- Bremse: zweiter Gruss direkt danach -> keiner ----------
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '111', 'text', 'Hallo', 'tool_called', false,
         'has_file', false, 'signal', '', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL claim_persona_sticker [Bremse greift nicht: %]', r; END IF;

  -- ---------- Gruss mit Inhalt / mit Werkzeug -> keiner ----------
  PERFORM core.fn_notify_resolve('persona_sticker', 'powner');
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '111', 'text', 'Hallo, buch 5 Euro Kaffee',
         'tool_called', false, 'has_file', false, 'signal', '', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [Gruss mit Inhalt: %]', r; END IF;
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '111', 'text', 'Hallo', 'tool_called', true,
         'has_file', false, 'signal', 'FRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [Gruss mit Werkzeug: %]', r; END IF;

  -- ---------- top: endgueltig bestaetigte Karte dieses Laufs + FRAME, Set der Persona (butler) ----------
  INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, opened_at, released_at, expires_at, approved)
  VALUES (222, 'gate-ok', true, now(), now(), now() + interval '2 minutes', true);
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'buch 5 Euro Kaffee',
         'tool_called', true, 'has_file', false, 'signal', 'NOFRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [top trotz NOFRAME: %]', r; END IF;
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'buch 5 Euro Kaffee',
         'tool_called', true, 'has_file', true, 'signal', 'FRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS DISTINCT FROM 'butler_top' THEN
    RAISE EXCEPTION 'FAIL claim_persona_sticker [top vor hmm, butler-Set: %]', r; END IF;

  -- ---------- Antwort ist der feste Leer-/Fehler-Hinweis (reply_ok=false) -> nie ein Daumen hoch davor ----------
  PERFORM core.fn_notify_resolve('persona_sticker', 'mina');
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'buch 5 Euro Kaffee',
         'tool_called', true, 'has_file', false, 'signal', 'FRAME', 'reply_ok', false, 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [top vor Fehler-Hinweis: %]', r; END IF;

  -- ---------- keine endgueltige Freigabe (Ablehnung/Timeout/Owner lehnt nach Mitglied ab) -> kein top ----------
  PERFORM core.fn_notify_resolve('persona_sticker', 'mina');
  UPDATE agent.hitl_pending SET approved = NULL WHERE execution_id = 'gate-ok';
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'buch 5 Euro Kaffee',
         'tool_called', true, 'has_file', false, 'signal', 'FRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [top ohne Freigabe: %]', r; END IF;

  -- ---------- alte bestaetigte Karte vor der Nachricht -> kein top ----------
  DELETE FROM agent.hitl_pending WHERE chat_id = 222;
  INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, opened_at, released_at, expires_at, approved)
  VALUES (222, 'gate-old', true, now() - interval '1 hour', now() - interval '59 minutes', now() - interval '57 minutes', true);
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'wie ist mein Kontostand',
         'tool_called', true, 'has_file', false, 'signal', 'FRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [alte Karte zaehlt: %]', r; END IF;

  -- ---------- hmm: Datei + FRAME; Datei + NOFRAME -> keiner ----------
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', '', 'tool_called', true,
         'has_file', true, 'signal', 'NOFRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [hmm trotz NOFRAME: %]', r; END IF;
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', '', 'tool_called', true,
         'has_file', true, 'signal', 'FRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS DISTINCT FROM 'butler_hmm' THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [hmm: %]', r; END IF;

  -- ---------- yay: Einrichtung in diesem Lauf fertig -> trotz Bremse ----------
  INSERT INTO core.notification_state (source, key, state, last_fired_at)
  VALUES ('onboarding', 'all_done:mina', 'fired', now())
  ON CONFLICT (source, key) DO UPDATE SET state = 'fired', last_fired_at = now();
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'fertig', 'tool_called', true,
         'has_file', false, 'signal', 'FRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS DISTINCT FROM 'butler_yay' THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [yay trotz Bremse: %]', r; END IF;
  -- Werkzeug lief, Router schrieb Prosa statt eines Signals -> gilt als NOFRAME (wie das Router-Gedaechtnis)
  PERFORM core.fn_notify_resolve('persona_sticker', 'mina');
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'fertig', 'tool_called', true,
         'has_file', false, 'signal', '', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [yay ohne Signal nach Werkzeug: %]', r; END IF;
  UPDATE core.notification_state SET last_fired_at = now() - interval '1 day' WHERE source = 'onboarding' AND key = 'all_done:mina';
  PERFORM core.fn_notify_resolve('persona_sticker', 'mina');
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'fertig', 'tool_called', true,
         'has_file', false, 'signal', 'FRAME', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [alter yay-Latch zaehlt: %]', r; END IF;

  -- ---------- Persona gewaehlt: hallo im Set trotz Bremse, setzt die Bremse ----------
  PERFORM core.fn_should_notify('persona_sticker', 'mina', interval '4 hours');
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'event', 'persona_chosen', 'run_started_at', v_now));
  IF r->>'sticker' IS DISTINCT FROM 'butler_hallo' THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [Persona-Wahl: %]', r; END IF;
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'Hallo', 'tool_called', false,
         'has_file', false, 'signal', '', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [Bremse nach Persona-Wahl: %]', r; END IF;

  -- ---------- Bremse 0 = aus; Aus-Schalter; unbekannter Absender ----------
  INSERT INTO core.config (category, key, value, package, value_type, minimum, maximum)
  VALUES ('persona', 'sticker_cooldown_hours', '0', 'core', 'integer', 0, 168)
  ON CONFLICT (category, key) DO UPDATE SET value = '0';
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'text', 'Hallo', 'tool_called', false,
         'has_file', false, 'signal', '', 'run_started_at', v_now));
  IF r->>'sticker' IS DISTINCT FROM 'butler_hallo' THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [Bremse 0: %]', r; END IF;
  INSERT INTO core.config (category, key, value, package, value_type)
  VALUES ('persona', 'stickers_enabled', 'false', 'core', 'boolean')
  ON CONFLICT (category, key) DO UPDATE SET value = 'false';
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '222', 'event', 'persona_chosen', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL OR (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim_persona_sticker [Aus-Schalter: %]', r; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'persona' AND key = 'stickers_enabled';
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', '999', 'text', 'Hallo', 'tool_called', false,
         'has_file', false, 'signal', '', 'run_started_at', v_now));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [unbekannter Absender: %]', r; END IF;
  r := agent.fn_claim_persona_sticker(jsonb_build_object('chat_id', 'kaputt'));
  IF r->>'sticker' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_persona_sticker [kaputte chat_id: %]', r; END IF;

  RAISE NOTICE 'PASS fn_claim_persona_sticker [Prioritaet, Set je Persona, endgueltige Freigabe dieses Laufs, NOFRAME, Bremse + Ausnahmen, Aus-Schalter]';
END $$;

ROLLBACK;
