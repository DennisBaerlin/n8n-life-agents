-- tests/db/core/test_fn_claim_reaction.sql
-- agent.fn_claim_reaction(p): hoechstens EINE Reaktion je Aufruf, Entscheidung nur in der DB.
--   * seen 👀 (Lebenszeichen), done 👌 (Karte dieses Laufs endgueltig bestaetigt + FRAME + reply_ok)
--   * answer = Stimmung statt Text (ohne Werkzeug, react_only), ohne Obergrenze
--   * mood = Stimmung neben Text: nach Werkzeug nur FRAME, ohne Werkzeug nur mit Text, nie mit Sticker, nie NOFRAME,
--     nie bei reply_ok=false; Tages-Obergrenze je Person nach Stil (expressive N, neutral max(1,N-1), terse 1, 0 = aus)
--   * dieselbe Art an derselben Nachricht nie zweimal; Zeilen > 30 Tage weg; Aus-Schalter; unbekannter Absender
BEGIN;

CREATE FUNCTION pg_temp.rx(p_chat bigint, p_msg bigint, p_extra jsonb) RETURNS jsonb LANGUAGE sql AS $$
    SELECT agent.fn_claim_reaction(jsonb_build_object('chat_id', p_chat::text, 'message_id', p_msg, 'event', 'reply',
             'signal', '', 'mood', '', 'react_only', false, 'has_text', true, 'tool_called', false, 'reply_ok', true,
             'run_started_at', now()::text, 'sticker', '') || p_extra);
$$;

DO $$
BEGIN
  IF to_regclass('agent.orchestrator_chat_memory') IS NULL THEN
    CREATE TABLE agent.orchestrator_chat_memory (id SERIAL PRIMARY KEY, session_id VARCHAR(255) NOT NULL, message JSONB NOT NULL);
  END IF;
  DELETE FROM agent.orchestrator_chat_memory WHERE session_id IN ('111', '222');
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'claim_reaction fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Erika','last_name','Mustermann','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel','role','partner',
                                 'birth_date','1985-01-01','language','de','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;
  DELETE FROM agent.reaction_log;
  DELETE FROM agent.hitl_pending WHERE chat_id IN (111, 222);
  INSERT INTO core.config (category, key, value, package, value_type, minimum, maximum)
  VALUES ('persona', 'mood_reactions_per_day', '5', 'core', 'integer', 0, 10)
  ON CONFLICT (category, key) DO UPDATE SET value = '5';
  INSERT INTO core.config (category, key, value, package, value_type)
  VALUES ('persona', 'reactions_enabled', 'true', 'core', 'boolean')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true';
END $$;

DO $$
DECLARE
  r   jsonb;
  i   int;
  v_n int;
BEGIN
  -- ---------- seen: 👀, einmal je Nachricht ----------
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '111', 'message_id', 10, 'event', 'seen'));
  IF r->>'emoji' IS DISTINCT FROM '👀' OR r->>'kind' IS DISTINCT FROM 'seen' OR (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim_reaction [seen: %]', r; END IF;
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '111', 'message_id', 10, 'event', 'seen'));
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [seen doppelt: %]', r; END IF;

  -- ---------- done: endgueltig bestaetigte Karte dieses Laufs + FRAME + reply_ok ----------
  INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, opened_at, released_at, expires_at, approved)
  VALUES (111, 'gate-ok', true, now(), now(), now() + interval '2 minutes', true);
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"NOFRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done trotz NOFRAME: %]', r; END IF;
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"FRAME","reply_ok":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done vor Fehler-Hinweis: %]', r; END IF;
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"FRAME","mood":"CHEER"}');
  IF r->>'emoji' IS DISTINCT FROM '👌' OR r->>'kind' IS DISTINCT FROM 'done' THEN
    RAISE EXCEPTION 'FAIL claim_reaction [done vor Stimmung, ersetzt 👀: %]', r; END IF;
  -- Karte nicht endgueltig bestaetigt bzw. aus einem frueheren Lauf -> kein 👌
  UPDATE agent.hitl_pending SET approved = NULL WHERE execution_id = 'gate-ok';
  r := pg_temp.rx(111, 11, '{"tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done ohne Freigabe: %]', r; END IF;
  UPDATE agent.hitl_pending SET approved = true, opened_at = now() - interval '1 hour', released_at = now() - interval '59 minutes',
         expires_at = now() - interval '58 minutes' WHERE execution_id = 'gate-ok';
  r := pg_temp.rx(111, 11, '{"tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [alte Karte zaehlt: %]', r; END IF;
  DELETE FROM agent.hitl_pending WHERE chat_id = 111;

  -- ---------- answer: Stimmung statt Text, ohne Obergrenze ----------
  r := pg_temp.rx(111, 20, '{"mood":"love","react_only":true,"has_text":false}');
  IF r->>'emoji' IS DISTINCT FROM '❤' OR r->>'kind' IS DISTINCT FROM 'answer' THEN
    RAISE EXCEPTION 'FAIL claim_reaction [answer LOVE: %]', r; END IF;
  IF r->>'emoji' <> U&'\2764' THEN RAISE EXCEPTION 'FAIL claim_reaction [❤ mit VS16: %]', r; END IF;
  -- react_only zaehlt nur ohne Werkzeug
  r := pg_temp.rx(111, 21, '{"mood":"FUN","react_only":true,"tool_called":true,"signal":"FRAME"}');
  IF r->>'kind' IS DISTINCT FROM 'mood' THEN RAISE EXCEPTION 'FAIL claim_reaction [react_only mit Werkzeug: %]', r; END IF;

  -- ---------- Sperren der Stimmung ----------
  r := pg_temp.rx(111, 30, '{"mood":"ANGRY"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [unbekannte Stimmung: %]', r; END IF;
  r := pg_temp.rx(111, 31, '{"mood":"CHEER","tool_called":true,"signal":"NOFRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [NOFRAME: %]', r; END IF;
  r := pg_temp.rx(111, 32, '{"mood":"CHEER","tool_called":true,"signal":""}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [Werkzeug ohne Signal: %]', r; END IF;
  r := pg_temp.rx(111, 33, '{"mood":"CHEER","tool_called":true,"signal":"FRAME","reply_ok":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [reply_ok=false: %]', r; END IF;
  r := pg_temp.rx(111, 34, '{"mood":"LOVE","react_only":true,"has_text":false,"reply_ok":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [answer bei reply_ok=false: %]', r; END IF;
  r := pg_temp.rx(111, 35, '{"mood":"CHEER","tool_called":true,"signal":"FRAME","sticker":"butler_top"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [Sticker im Lauf: %]', r; END IF;
  r := pg_temp.rx(111, 36, '{"mood":"FUN","has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [ohne Werkzeug ohne Text: %]', r; END IF;
  r := pg_temp.rx(111, 37, '{"mood":"CHEER","signal":"NOFRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [NOFRAME ohne Werkzeug: %]', r; END IF;
  -- 👀 bleibt stehen: an der Datei-Nachricht 10 (seen oben) keine Stimmung, weder neben Text noch statt Text
  r := pg_temp.rx(111, 10, '{"mood":"CHEER","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [Stimmung ersetzt 👀: %]', r; END IF;
  r := pg_temp.rx(111, 10, '{"mood":"LOVE","react_only":true,"has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [answer ersetzt 👀: %]', r; END IF;

  -- ---------- Obergrenze: Stil neutral (keine Historie) bei 5 -> 4 je Tag; bisher 1 mood (msg 21) ----------
  DELETE FROM agent.reaction_log WHERE person_id = 'powner' AND kind = 'mood';
  FOR i IN 1..4 LOOP
    r := pg_temp.rx(111, 100 + i, '{"mood":"CHEER","tool_called":true,"signal":"FRAME"}');
    IF r->>'emoji' IS DISTINCT FROM '🎉' OR r->>'kind' IS DISTINCT FROM 'mood' THEN
      RAISE EXCEPTION 'FAIL claim_reaction [neutral Nr. %: %]', i, r; END IF;
  END LOOP;
  r := pg_temp.rx(111, 105, '{"mood":"CHEER","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [neutral 5. ueber Grenze: %]', r; END IF;
  -- REACT + Text zaehlt mit, reine Reaktion nicht
  r := pg_temp.rx(111, 106, '{"mood":"FUN"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [REACT+Text ueber Grenze: %]', r; END IF;
  r := pg_temp.rx(111, 107, '{"mood":"RELIEF","react_only":true,"has_text":false}');
  IF r->>'emoji' IS DISTINCT FROM '🙏' THEN RAISE EXCEPTION 'FAIL claim_reaction [answer trotz Grenze: %]', r; END IF;
  -- Doppel-Insert: dieselbe Nachricht bekommt keine zweite Stimmung (auch unter der Grenze)
  DELETE FROM agent.reaction_log WHERE person_id = 'powner' AND message_id = 104;
  r := pg_temp.rx(111, 103, '{"mood":"LOVE","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [zweite Stimmung an derselben Nachricht: %]', r; END IF;
  -- gestrige Stimmungen zaehlen nicht, Zeilen > 30 Tage werden geloescht
  UPDATE agent.reaction_log SET created_at = now() - interval '1 day' WHERE person_id = 'powner';
  INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji, created_at)
  VALUES ('powner', 111, 1, 'mood', '🎉', now() - interval '31 days');
  r := pg_temp.rx(111, 108, '{"mood":"CHEER","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS DISTINCT FROM '🎉' THEN RAISE EXCEPTION 'FAIL claim_reaction [neuer Tag: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.reaction_log WHERE person_id = 'powner' AND created_at < now() - interval '30 days') THEN
    RAISE EXCEPTION 'FAIL claim_reaction [Aufbewahrung 30 Tage]'; END IF;

  -- ---------- Stil expressive: Grenze = Wert (3) ----------
  UPDATE core.config SET value = '3' WHERE category = 'persona' AND key = 'mood_reactions_per_day';
  FOR i IN 1..6 LOOP
    INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('222', jsonb_build_object('type', 'human', 'content', 'Na klar 😀'));
  END LOOP;
  FOR i IN 1..4 LOOP
    r := pg_temp.rx(222, 200 + i, '{"mood":"FUN","tool_called":true,"signal":"frame"}');
    IF (i <= 3) <> (r->>'emoji' IS NOT DISTINCT FROM '😁') THEN
      RAISE EXCEPTION 'FAIL claim_reaction [expressive Nr. %: %]', i, r; END IF;
  END LOOP;
  -- Stil terse: hoechstens 1, auch bei hohem Wert
  DELETE FROM agent.reaction_log WHERE person_id = 'lena';
  DELETE FROM agent.orchestrator_chat_memory WHERE session_id = '222';
  FOR i IN 1..6 LOOP
    INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('222', jsonb_build_object('type', 'human', 'content', 'ok'));
  END LOOP;
  UPDATE core.config SET value = '10' WHERE category = 'persona' AND key = 'mood_reactions_per_day';
  r := pg_temp.rx(222, 210, '{"mood":"FUN","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS DISTINCT FROM '😁' THEN RAISE EXCEPTION 'FAIL claim_reaction [terse 1.: %]', r; END IF;
  r := pg_temp.rx(222, 211, '{"mood":"FUN","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [terse 2.: %]', r; END IF;
  -- 0 = keine Stimmung neben Text; die reine Reaktion bleibt
  DELETE FROM agent.reaction_log WHERE person_id = 'lena';
  UPDATE core.config SET value = '0' WHERE category = 'persona' AND key = 'mood_reactions_per_day';
  r := pg_temp.rx(222, 212, '{"mood":"FUN","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [Grenze 0: %]', r; END IF;
  r := pg_temp.rx(222, 213, '{"mood":"LOVE","react_only":true,"has_text":false}');
  IF r->>'emoji' IS DISTINCT FROM '❤' THEN RAISE EXCEPTION 'FAIL claim_reaction [answer bei Grenze 0: %]', r; END IF;
  SELECT count(*) INTO v_n FROM agent.reaction_log WHERE person_id = 'lena';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL claim_reaction [Protokoll lena: % Zeilen]', v_n; END IF;

  -- ---------- Aus-Schalter, unbekannter Absender, kaputte Eingaben ----------
  UPDATE core.config SET value = 'false' WHERE category = 'persona' AND key = 'reactions_enabled';
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '111', 'message_id', 300, 'event', 'seen'));
  IF r->>'emoji' IS NOT NULL OR (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim_reaction [Aus-Schalter: %]', r; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'persona' AND key = 'reactions_enabled';
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '999', 'message_id', 300, 'event', 'seen'));
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [unbekannter Absender: %]', r; END IF;
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', 'kaputt', 'message_id', 300, 'event', 'seen'));
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [kaputte chat_id: %]', r; END IF;
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '111', 'event', 'seen'));
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [ohne message_id: %]', r; END IF;
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '111', 'message_id', 301, 'event', 'other'));
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [unbekanntes Ereignis: %]', r; END IF;

  RAISE NOTICE 'PASS fn_claim_reaction [seen/done/answer/mood, Sperren, Obergrenze je Stil + Tag, Doppel, 30 Tage, Aus-Schalter]';
END $$;

-- ---------- DB-Gesetz: Koppel-CHECK kind <-> emoji, eine Art je Nachricht ----------
DO $$
BEGIN
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 900, 'seen', '🎉');
    RAISE EXCEPTION 'FAIL reaction_log [seen mit 🎉 angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 900, 'mood', '👌');
    RAISE EXCEPTION 'FAIL reaction_log [mood mit 👌 angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 900, 'mood', U&'\2764\FE0F');
    RAISE EXCEPTION 'FAIL reaction_log [❤ mit VS16 angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 901, 'mood', '🙏');
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 901, 'mood', '😁');
    RAISE EXCEPTION 'FAIL reaction_log [zweite mood-Zeile je Nachricht angenommen]';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('niemand', 111, 902, 'seen', '👀');
    RAISE EXCEPTION 'FAIL reaction_log [unbekannte Person angenommen]';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS reaction_log [Koppel-CHECK, ❤ ohne VS16, UNIQUE je Art, FK Person]';
END $$;

ROLLBACK;
