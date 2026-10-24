-- tests/db/core/test_fn_set_person_language.sql
-- agent.fn_set_person_language(p): Callback-Handler des Sprach-Pickers (Prefix lang:<person_id>:<code>,
--   core.callback_handlers member_permeable=true). Zero-Trust: re-resolvt den Absender selbst.
--   * Owner setzt jede Person; Mitglied nur sich selbst; fremde Person durch Mitglied -> abgelehnt
--   * unbekannte Person / ungueltiger Code / unaufgeloester Absender -> {ok:false, toast}, kein Write
--   * schreibt genau language der Zielperson; Toast in der Sprache des TIPPENDEN
-- Ueber den Dispatcher (core.fn_dispatch_callback) mitgeprueft: der Prefix ist registriert und member-permeabel.
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'set_person_language fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','P','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111),
              jsonb_build_object('person_id','mina','first_name','Mina','last_name','P','role','partner',
                                 'birth_date','1985-01-01','telegram_user_id',222),
              jsonb_build_object('person_id','kid','first_name','Kid','last_name','P','role','child',
                                 'birth_date','2015-01-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;

  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.lang.saved', 'de', 'DE {name}={language}', 'core'),
    ('core.lang.saved', 'ko', 'KO {name}={language}', 'core'),
    ('core.lang.saved', 'en', 'EN {name}={language}', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('lang', 'agent.fn_set_person_language', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;

  -- ---------- Owner setzt Mina auf ko (Toast in Owner-Sprache de) ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'lang:mina:ko', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'person_id' IS DISTINCT FROM 'mina' THEN
    RAISE EXCEPTION 'FAIL set_person_language [Owner setzt Mina: %]', r; END IF;
  IF r->>'toast' IS DISTINCT FROM 'DE Mina=한국어' THEN
    RAISE EXCEPTION 'FAIL set_person_language [Toast nicht in Owner-Sprache: %]', r; END IF;
  IF (SELECT pp->>'language' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
       WHERE c.name = 'family' AND pp->>'person_id' = 'mina') IS DISTINCT FROM 'ko' THEN
    RAISE EXCEPTION 'FAIL set_person_language [ko nicht gespeichert]'; END IF;

  -- ---------- Mitglied setzt sich selbst (Toast in der NEUEN eigenen Sprache) ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'lang:mina:en', 'chat_id', '222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'EN Mina=English' THEN
    RAISE EXCEPTION 'FAIL set_person_language [Mitglied selbst: %]', r; END IF;

  -- ---------- Mitglied versucht fremde Person (Owner) ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'lang:powner:ko', 'chat_id', '222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'toast' IS NULL THEN
    RAISE EXCEPTION 'FAIL set_person_language [Mitglied setzt Owner: %]', r; END IF;
  IF (SELECT pp->>'language' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
       WHERE c.name = 'family' AND pp->>'person_id' = 'powner') IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL set_person_language [Owner-Sprache durch Mitglied geaendert]'; END IF;

  -- ---------- unbekannte Person / ungueltiger Code / kaputte Daten ----------
  r := agent.fn_set_person_language(jsonb_build_object('data', 'lang:nobody:ko', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'toast' IS NULL THEN
    RAISE EXCEPTION 'FAIL set_person_language [unbekannte Person: %]', r; END IF;
  r := agent.fn_set_person_language(jsonb_build_object('data', 'lang:kid:fr', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_person_language [ungueltiger Code: %]', r; END IF;
  r := agent.fn_set_person_language(jsonb_build_object('data', 'lang', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_person_language [kaputte Daten: %]', r; END IF;

  -- ---------- unaufgeloester Absender (direkter Aufruf am Dispatcher vorbei) ----------
  r := agent.fn_set_person_language(jsonb_build_object('data', 'lang:kid:ko', 'chat_id', '999'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_person_language [unaufgeloester Absender: %]', r; END IF;
  IF (SELECT pp ? 'language' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
       WHERE c.name = 'family' AND pp->>'person_id' = 'kid') THEN
    RAISE EXCEPTION 'FAIL set_person_language [Kid trotz Ablehnung geschrieben]'; END IF;

  RAISE NOTICE 'PASS fn_set_person_language [Owner/Mitglied-Auth, Toast-Sprache, Ablehnungen ohne Write]';
END $$;

ROLLBACK;
