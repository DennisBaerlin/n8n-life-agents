-- tests/db/core/test_fn_chat_style.sql
-- agent.fn_chat_style(chat_id): Stil-Stufe aus den letzten 20 Nutzer-Nachrichten an den Router.
--   * < 5 Nachrichten -> neutral; >= 30 % mit Emoji -> expressive; kein Emoji + Schnitt <= 25 Zeichen -> terse
--   * [attachment ...]-Marker und /befehle zaehlen nicht; nur type 'human'; nur die juengsten 20
--   * NULL-Chat / Tabelle fehlt -> neutral
BEGIN;

DO $$
BEGIN
  IF to_regclass('agent.orchestrator_chat_memory') IS NULL THEN
    CREATE TABLE agent.orchestrator_chat_memory (id SERIAL PRIMARY KEY, session_id VARCHAR(255) NOT NULL, message JSONB NOT NULL);
  END IF;
  DELETE FROM agent.orchestrator_chat_memory WHERE session_id IN ('900401', '900402', '900403', '900404', '900405', '900406');
END $$;

DO $$
DECLARE
  i int;
BEGIN
  -- zu wenig Nachrichten (4) -> neutral, auch wenn alle kurz sind
  FOR i IN 1..4 LOOP
    INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('900401', jsonb_build_object('type', 'human', 'content', 'ok'));
  END LOOP;
  IF agent.fn_chat_style(900401) IS DISTINCT FROM 'neutral' THEN
    RAISE EXCEPTION 'FAIL chat_style [< 5 Nachrichten: %]', agent.fn_chat_style(900401); END IF;

  -- 2 von 6 mit Emoji (33 %) -> expressive; ai-Zeilen mit Emoji zaehlen nicht
  INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES
    ('900402', '{"type":"human","content":"Wie steht mein Girokonto?"}'),
    ('900402', '{"type":"human","content":"Super, danke 😀"}'),
    ('900402', '{"type":"human","content":"Buch bitte 12 Euro Kaffee"}'),
    ('900402', '{"type":"human","content":"Juhu ☀ endlich Wochenende"}'),
    ('900402', '{"type":"human","content":"Was kostet mein Kredit im Monat?"}'),
    ('900402', '{"type":"human","content":"Und mein Sparziel?"}'),
    ('900402', '{"type":"ai","content":"🎉 🎉 🎉"}');
  IF agent.fn_chat_style(900402) IS DISTINCT FROM 'expressive' THEN
    RAISE EXCEPTION 'FAIL chat_style [33 %% Emoji: %]', agent.fn_chat_style(900402); END IF;

  -- kurz, kein Emoji -> terse; genau 5 zaehlen (/help und der reine Anhang-Marker fallen weg)
  INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES
    ('900403', '{"type":"human","content":"Kontostand?"}'),
    ('900403', '{"type":"human","content":"ok"}'),
    ('900403', '{"type":"human","content":"ja"}'),
    ('900403', '{"type":"human","content":"buch 5 Euro Brot"}'),
    ('900403', '{"type":"human","content":"[attachment file_id=x1 type=photo] Beleg"}'),
    ('900403', '{"type":"human","content":"/help"}'),
    ('900403', '{"type":"human","content":"[attachment file_id=x2 type=document ext=pdf]"}');
  IF agent.fn_chat_style(900403) IS DISTINCT FROM 'terse' THEN
    RAISE EXCEPTION 'FAIL chat_style [terse: %]', agent.fn_chat_style(900403); END IF;
  -- eine zaehlende Nachricht weniger -> 4 -> neutral (zaehlten Befehl/Marker mit, waeren es 6)
  DELETE FROM agent.orchestrator_chat_memory WHERE session_id = '900403' AND message->>'content' = 'ok';
  IF agent.fn_chat_style(900403) IS DISTINCT FROM 'neutral' THEN
    RAISE EXCEPTION 'FAIL chat_style [Befehl/Marker zaehlen mit: %]', agent.fn_chat_style(900403); END IF;

  -- lange Saetze ohne Emoji -> neutral
  FOR i IN 1..6 LOOP
    INSERT INTO agent.orchestrator_chat_memory (session_id, message)
    VALUES ('900404', jsonb_build_object('type', 'human', 'content', 'Kannst du mir bitte sagen, wie viel ich diesen Monat ausgegeben habe?'));
  END LOOP;
  IF agent.fn_chat_style(900404) IS DISTINCT FROM 'neutral' THEN
    RAISE EXCEPTION 'FAIL chat_style [lang ohne Emoji: %]', agent.fn_chat_style(900404); END IF;

  -- nur die juengsten 20: 30 alte mit Emoji, danach 20 kurze ohne -> terse
  FOR i IN 1..30 LOOP
    INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('900405', jsonb_build_object('type', 'human', 'content', 'Hallo 🎉'));
  END LOOP;
  FOR i IN 1..20 LOOP
    INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('900405', jsonb_build_object('type', 'human', 'content', 'ok danke'));
  END LOOP;
  IF agent.fn_chat_style(900405) IS DISTINCT FROM 'terse' THEN
    RAISE EXCEPTION 'FAIL chat_style [Fenster 20: %]', agent.fn_chat_style(900405); END IF;

  -- Inhalt kein String (Tool-Aufruf-Zeile) -> ignoriert; leerer Chat und NULL -> neutral
  INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('900406', '{"type":"human","content":[{"x":1}]}');
  IF agent.fn_chat_style(900406) IS DISTINCT FROM 'neutral' OR agent.fn_chat_style(NULL) IS DISTINCT FROM 'neutral' THEN
    RAISE EXCEPTION 'FAIL chat_style [leer/NULL]'; END IF;

  RAISE NOTICE 'PASS fn_chat_style [Mindestzahl, expressive/terse/neutral, Filter, Fenster 20, NULL]';
END $$;

ROLLBACK;
