-- tests/db/core/test_fn_claim_reaction.sql
-- agent.fn_claim_reaction(p): hoechstens eine Reaktion je Aufruf, Entscheidung nur in der DB.
--   * seen 👀 (Lebenszeichen), done 👌 (Karte dieses Laufs endgueltig bestaetigt + FRAME + reply_ok, nur ohne Folgetext)
--   * answer = Stimmung statt Text (ohne Werkzeug, react_only)
--   * keine Stimmung neben einer Antwort (die Reaktion neben langem Text erzeugt am Handy einen Reaktions-Zaehler)
--   * dieselbe Art an derselben Nachricht nie zweimal; Zeilen > 30 Tage weg; Aus-Schalter; unbekannter Absender
BEGIN;

CREATE FUNCTION pg_temp.rx(p_chat bigint, p_msg bigint, p_extra jsonb) RETURNS jsonb LANGUAGE sql AS $$
    SELECT agent.fn_claim_reaction(jsonb_build_object('chat_id', p_chat::text, 'message_id', p_msg, 'event', 'reply',
             'signal', '', 'mood', '', 'react_only', false, 'has_text', true, 'tool_called', false, 'reply_ok', true,
             'run_started_at', now()::text, 'sticker', '') || p_extra);
$$;

DO $$
BEGIN
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
  INSERT INTO core.config (category, key, value, package, value_type)
  VALUES ('persona', 'reactions_enabled', 'true', 'core', 'boolean')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true';
END $$;

DO $$
DECLARE
  r   jsonb;
  v_n int;
BEGIN
  -- ---------- seen: 👀, einmal je Nachricht ----------
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '111', 'message_id', 10, 'event', 'seen'));
  IF r->>'emoji' IS DISTINCT FROM '👀' OR r->>'kind' IS DISTINCT FROM 'seen' OR (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim_reaction [seen: %]', r; END IF;
  r := agent.fn_claim_reaction(jsonb_build_object('chat_id', '111', 'message_id', 10, 'event', 'seen'));
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [seen doppelt: %]', r; END IF;

  -- ---------- done: endgueltig bestaetigte Karte dieses Laufs + FRAME + reply_ok, nur ohne Folgetext ----------
  INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, opened_at, released_at, expires_at, approved)
  VALUES (111, 'gate-ok', true, now(), now(), now() + interval '2 minutes', true);
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"NOFRAME","has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done trotz NOFRAME: %]', r; END IF;
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"FRAME","reply_ok":false,"has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done vor Fehler-Hinweis: %]', r; END IF;
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"FRAME","sticker":"butler_top","has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done trotz Sticker: %]', r; END IF;
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done neben Folgetext: %]', r; END IF;
  r := pg_temp.rx(111, 10, '{"tool_called":true,"signal":"FRAME","has_text":false,"mood":"CHEER"}');
  IF r->>'emoji' IS DISTINCT FROM '👌' OR r->>'kind' IS DISTINCT FROM 'done' THEN
    RAISE EXCEPTION 'FAIL claim_reaction [done ohne Folgetext, ersetzt 👀: %]', r; END IF;
  UPDATE agent.hitl_pending SET approved = NULL WHERE execution_id = 'gate-ok';
  r := pg_temp.rx(111, 11, '{"tool_called":true,"signal":"FRAME","has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [done ohne Freigabe: %]', r; END IF;
  UPDATE agent.hitl_pending SET approved = true, opened_at = now() - interval '1 hour', released_at = now() - interval '59 minutes',
         expires_at = now() - interval '58 minutes' WHERE execution_id = 'gate-ok';
  r := pg_temp.rx(111, 11, '{"tool_called":true,"signal":"FRAME","has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [alte Karte zaehlt: %]', r; END IF;
  DELETE FROM agent.hitl_pending WHERE chat_id = 111;

  -- ---------- answer: Stimmung statt Text ----------
  r := pg_temp.rx(111, 20, '{"mood":"love","react_only":true,"has_text":false}');
  IF r->>'emoji' IS DISTINCT FROM '❤' OR r->>'kind' IS DISTINCT FROM 'answer' THEN
    RAISE EXCEPTION 'FAIL claim_reaction [answer LOVE: %]', r; END IF;
  IF r->>'emoji' <> U&'\2764' THEN RAISE EXCEPTION 'FAIL claim_reaction [❤ mit VS16: %]', r; END IF;
  r := pg_temp.rx(111, 21, '{"mood":"RELIEF","react_only":true,"has_text":false}');
  IF r->>'emoji' IS DISTINCT FROM '🙏' THEN RAISE EXCEPTION 'FAIL claim_reaction [answer RELIEF: %]', r; END IF;
  -- Sperren der reinen Reaktion
  r := pg_temp.rx(111, 22, '{"mood":"FUN","react_only":true,"tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [react_only mit Werkzeug: %]', r; END IF;
  r := pg_temp.rx(111, 23, '{"mood":"ANGRY","react_only":true,"has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [unbekannte Stimmung: %]', r; END IF;
  r := pg_temp.rx(111, 24, '{"mood":"LOVE","react_only":true,"has_text":false,"reply_ok":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [answer bei reply_ok=false: %]', r; END IF;
  r := pg_temp.rx(111, 25, '{"mood":"LOVE","react_only":true,"has_text":false,"signal":"NOFRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [answer bei NOFRAME: %]', r; END IF;
  -- 👀 bleibt stehen
  r := pg_temp.rx(111, 10, '{"mood":"LOVE","react_only":true,"has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [answer ersetzt 👀: %]', r; END IF;
  -- Doppel: dieselbe Nachricht bekommt keine zweite Stimmung
  r := pg_temp.rx(111, 20, '{"mood":"CHEER","react_only":true,"has_text":false}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [zweite Stimmung an derselben Nachricht: %]', r; END IF;

  -- ---------- keine Stimmung neben einer Antwort ----------
  r := pg_temp.rx(111, 30, '{"mood":"CHEER","tool_called":true,"signal":"FRAME"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [Stimmung neben Spezialisten-Antwort: %]', r; END IF;
  r := pg_temp.rx(111, 31, '{"mood":"FUN"}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [Stimmung neben eigenem Text: %]', r; END IF;
  r := pg_temp.rx(222, 32, '{"mood":"LOVE","has_text":true,"react_only":true}');
  IF r->>'emoji' IS NOT NULL THEN RAISE EXCEPTION 'FAIL claim_reaction [react_only mit Text: %]', r; END IF;

  -- ---------- Aufbewahrung 30 Tage ----------
  INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji, created_at)
  VALUES ('powner', 111, 1, 'answer', '🎉', now() - interval '31 days');
  r := pg_temp.rx(111, 40, '{"mood":"CHEER","react_only":true,"has_text":false}');
  IF EXISTS (SELECT 1 FROM agent.reaction_log WHERE person_id = 'powner' AND created_at < now() - interval '30 days') THEN
    RAISE EXCEPTION 'FAIL claim_reaction [Aufbewahrung 30 Tage]'; END IF;
  SELECT count(*) INTO v_n FROM agent.reaction_log WHERE kind = 'mood';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL claim_reaction [mood-Zeilen: %]', v_n; END IF;

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

  RAISE NOTICE 'PASS fn_claim_reaction [seen/done ohne Folgetext/answer, keine Stimmung neben Text, Sperren, Doppel, 30 Tage, Aus-Schalter]';
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
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 900, 'answer', '👌');
    RAISE EXCEPTION 'FAIL reaction_log [answer mit 👌 angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 900, 'answer', U&'\2764\FE0F');
    RAISE EXCEPTION 'FAIL reaction_log [❤ mit VS16 angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 903, 'mood', '🙏');
    RAISE EXCEPTION 'FAIL reaction_log [abgeschaffte Art mood angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 901, 'answer', '🙏');
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('powner', 111, 901, 'answer', '😁');
    RAISE EXCEPTION 'FAIL reaction_log [zweite answer-Zeile je Nachricht angenommen]';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('niemand', 111, 902, 'seen', '👀');
    RAISE EXCEPTION 'FAIL reaction_log [unbekannte Person angenommen]';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS reaction_log [Arten ohne mood, Koppel-CHECK, ❤ ohne VS16, UNIQUE je Art, FK Person]';
END $$;

ROLLBACK;
