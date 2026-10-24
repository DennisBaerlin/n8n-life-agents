-- tests/db/core/test_fn_collect_chat_since.sql
-- core.fn_collect_chat_since(): per-Quelltabelle die NEUEN Owner-Nachrichten seit dem Watermark.
--   * id > guide_learn_watermark.last_seen_id (per agent_name; allererster Lauf -> 0)
--   * nur message->>'type'='human' (KI-Antworten ignoriert), nicht-leerer data.content
--   * Phase B: NUR die Session des Owners (Mitglieder + Harness-Sessions raus); Owner nicht gepairt -> nichts
--   * Phase B: Quellen = alle agent.*_chat_memory ausser orchestrator (dynamisch, neue Agenten docken an)
--   * Phase B: fehlende Watermark = 0 auch in einem laufenden Loop (neue Agent-Tabelle: erstes Gespraech zaehlt;
--     die einmalige Startmarke der Umstellung macht core:V023, nicht die fn); die fn schreibt nichts
-- Self-seedend (minimale n8n-Memory-Tabellen + family mit gepairtem Owner), BEGIN..ROLLBACK.
BEGIN;

-- n8n legt agent.<agent>_chat_memory ZUR LAUFZEIT an -> im hermetischen db_test fehlen sie.
CREATE TABLE IF NOT EXISTS agent.finance_chat_memory (id serial PRIMARY KEY, session_id text NOT NULL, message jsonb NOT NULL);
CREATE TABLE IF NOT EXISTS agent.orchestrator_chat_memory (id serial PRIMARY KEY, session_id text NOT NULL, message jsonb NOT NULL);
CREATE TABLE IF NOT EXISTS agent.zz_advisor_chat_memory (id serial PRIMARY KEY, session_id text NOT NULL, message jsonb NOT NULL);

DO $$
BEGIN
  DELETE FROM agent.guide_learn_watermark;
  DELETE FROM agent.core_contexts WHERE name = 'family';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
  VALUES ('family', 'test', 'static', 'prose', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','powner','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-01-01','telegram_user_id',123456789),
      jsonb_build_object('person_id','ppartner','first_name','Tom','last_name','Mustermann','role','partner','birth_date','1982-01-01','telegram_user_id',987654321)))),
    'agent', 'core');

  -- Fixtures: nur 1 ist sammelbar (Owner, human, nicht leer).
  INSERT INTO agent.finance_chat_memory (id, session_id, message) VALUES
    (1, '123456789', jsonb_build_object('type','human','data', jsonb_build_object('content','Wir haben ein neues Kind, Lisa, geboren am 2024-01-01'))),
    (2, '123456789', jsonb_build_object('type','ai',    'data', jsonb_build_object('content','Glueckwunsch! Soll ich das notieren?'))),
    (3, 'test_e2e_x', jsonb_build_object('type','human','data', jsonb_build_object('content','Harness-Rauschen das niemand lernen soll'))),
    (4, '123456789', jsonb_build_object('type','human','data', jsonb_build_object('content',''))),
    (5, '987654321', jsonb_build_object('type','human','data', jsonb_build_object('content','Mitglied: wir ziehen 2027 nach Berlin um')));
  INSERT INTO agent.orchestrator_chat_memory (id, session_id, message) VALUES
    (1, '123456789', jsonb_build_object('type','human','data', jsonb_build_object('content','Duplikat im Verteiler')));
  INSERT INTO agent.zz_advisor_chat_memory (id, session_id, message) VALUES
    (7, '123456789', jsonb_build_object('type','human','data', jsonb_build_object('content','Advisor-Nachricht des Owners')));

  -- ===== allererster Lauf (kein Watermark): Owner-human aus allen Quellen ausser orchestrator =====
  IF (SELECT array_agg(agent_name || ':' || source_id ORDER BY agent_name, source_id) FROM core.fn_collect_chat_since())
     IS DISTINCT FROM ARRAY['finance:1', 'zz_advisor:7'] THEN
    RAISE EXCEPTION 'FAIL collect [erster Lauf]: erwartet {finance:1, zz_advisor:7}, got %',
      (SELECT array_agg(agent_name || ':' || source_id) FROM core.fn_collect_chat_since());
  END IF;
  RAISE NOTICE 'PASS collect [nur Owner-human; ai/test/leer/Mitglied/orchestrator raus; neue Agent-Tabelle dockt an]';

  -- ===== Watermark-Vorschub: finance last_seen_id=1 -> finance nichts mehr; zz_advisor (keine Watermark) zaehlt ab 0 =====
  INSERT INTO agent.guide_learn_watermark (agent_name, last_seen_id) VALUES ('finance', 1);
  IF (SELECT array_agg(agent_name || ':' || source_id) FROM core.fn_collect_chat_since()) IS DISTINCT FROM ARRAY['zz_advisor:7'] THEN
    RAISE EXCEPTION 'FAIL collect [laufender Loop]: erwartet {zz_advisor:7} (finance vorgerueckt, neue Quelle ab 0), got %',
      (SELECT array_agg(agent_name || ':' || source_id) FROM core.fn_collect_chat_since());
  END IF;
  IF EXISTS (SELECT 1 FROM agent.guide_learn_watermark WHERE agent_name = 'zz_advisor') THEN
    RAISE EXCEPTION 'FAIL collect [read-only]: fn hat eine Watermark geschrieben';
  END IF;
  RAISE NOTICE 'PASS collect [laufender Loop: Watermark-Vorschub greift; Quelle ohne Watermark ab 0; read-only]';

  -- ===== Owner nicht gepairt -> nichts (fail-closed) =====
  UPDATE agent.core_contexts
     SET metadata = jsonb_set(metadata, '{facts,persons,0}', (metadata->'facts'->'persons'->0) - 'telegram_user_id')
   WHERE name = 'family';
  IF EXISTS (SELECT 1 FROM core.fn_collect_chat_since()) THEN
    RAISE EXCEPTION 'FAIL collect [Owner ungepairt]: sammelt trotzdem';
  END IF;
  RAISE NOTICE 'PASS collect [Owner ungepairt -> fail-closed]';
END $$;

ROLLBACK;
