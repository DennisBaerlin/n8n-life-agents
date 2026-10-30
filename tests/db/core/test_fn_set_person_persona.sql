-- tests/db/core/test_fn_set_person_persona.sql
-- agent.fn_set_person_persona(p): Callback-Handler des Persona-Pickers (Prefix persona:<person_id>:<code>,
--   core.callback_handlers member_permeable=true). Zero-Trust: re-resolvt den Absender selbst.
--   * Owner setzt jede Person; Mitglied nur sich selbst; fremde Person durch Mitglied -> abgelehnt
--   * unbekannte Person / ungueltiger Code / unaufgeloester Absender -> {ok:false, toast}, kein Write
--   * schreibt genau persona der Zielperson; 'neutral' = Key entfernt (eine Darstellung fuer "keine Persona")
--   * Toast in der Sprache des TIPPENDEN mit dem Persona-Namen aus dem Katalog
--   * fn_resolve_sender liefert persona (fehlt -> 'neutral')
-- Ueber den Dispatcher (core.fn_dispatch_callback) mitgeprueft: der Prefix ist registriert und member-permeabel.
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'set_person_persona fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','P','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111),
              jsonb_build_object('person_id','mina','first_name','Mina','last_name','P','role','partner',
                                 'birth_date','1985-01-01','language','ko','telegram_user_id',222),
              jsonb_build_object('person_id','kid','first_name','Kid','last_name','P','role','child',
                                 'birth_date','2015-01-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;

  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.persona.saved', 'de', 'DE {name}={persona}', 'core'),
    ('core.persona.saved', 'ko', 'KO {name}={persona}', 'core'),
    ('core.persona.saved', 'en', 'EN {name}={persona}', 'core'),
    ('core.persona.name.butler', 'de', 'Butler-de', 'core'),
    ('core.persona.name.butler', 'ko', 'Butler-ko', 'core'),
    ('core.persona.name.sage',   'ko', 'Sage-ko', 'core'),
    ('core.persona.name.neutral','de', 'Neutral-de', 'core'),
    ('core.persona.reset', 'de', 'DE reset {name}', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('persona', 'agent.fn_set_person_persona', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;

  -- ---------- Wertevorrat ist vorab angelegt (core:V031), auch ohne Seed ----------
  IF (SELECT count(*) FROM core.ui_personas WHERE code IN ('neutral','butler','sportscaster','sage')) <> 4 THEN
    RAISE EXCEPTION 'FAIL set_person_persona [core.ui_personas ohne Basis-Codes]'; END IF;

  -- ---------- fehlt persona -> fn_resolve_sender liefert neutral ----------
  IF agent.fn_resolve_sender(111)->>'persona' IS DISTINCT FROM 'neutral' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [resolve_sender ohne persona != neutral: %]', agent.fn_resolve_sender(111); END IF;

  -- ---------- Owner setzt sich selbst auf butler (Toast in Owner-Sprache de) ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'persona:powner:butler', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'person_id' IS DISTINCT FROM 'powner' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [Owner setzt sich: %]', r; END IF;
  IF r->>'toast' IS DISTINCT FROM 'DE Owner=Butler-de' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [Toast nicht in Owner-Sprache: %]', r; END IF;
  IF agent.fn_resolve_sender(111)->>'persona' IS DISTINCT FROM 'butler' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [butler nicht gespeichert/aufgeloest]'; END IF;
  -- eigene Wahl -> Hallo-Sticker des neuen Sets (der Orchestrator ruft dann fn_claim_persona_sticker)
  IF r->>'sticker_event' IS DISTINCT FROM 'persona_chosen' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [eigene Wahl ohne sticker_event: %]', r; END IF;

  -- erneuter Tipp auf dieselbe Persona (z. B. alte Picker-Karte) -> kein Sticker (sonst keine Bremse)
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'persona:powner:butler', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r ? 'sticker_event' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [gleiche Persona erneut mit sticker_event: %]', r; END IF;

  -- ---------- Owner setzt Mina (Toast in Owner-Sprache, NICHT Minas; kein Sticker im Owner-Chat) ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'persona:mina:butler', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'DE Mina=Butler-de' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [Owner setzt Mina: %]', r; END IF;
  IF r ? 'sticker_event' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [sticker_event bei fremder Person: %]', r; END IF;

  -- ---------- Mitglied setzt sich selbst (Toast in eigener Sprache ko) ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'persona:mina:sage', 'chat_id', '222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'KO Mina=Sage-ko'
     OR r->>'sticker_event' IS DISTINCT FROM 'persona_chosen' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [Mitglied selbst: %]', r; END IF;
  IF agent.fn_resolve_sender(222)->>'persona' IS DISTINCT FROM 'sage' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [sage nicht gespeichert]'; END IF;

  -- ---------- Mitglied versucht fremde Person (Owner) ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'persona:powner:sage', 'chat_id', '222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'not_allowed' OR r->>'toast' IS NULL THEN
    RAISE EXCEPTION 'FAIL set_person_persona [Mitglied setzt Owner: %]', r; END IF;
  IF agent.fn_resolve_sender(111)->>'persona' IS DISTINCT FROM 'butler' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [Owner-Persona durch Mitglied geaendert]'; END IF;

  -- ---------- neutral = Key entfernt, eigener Zurueck-Toast ----------
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'persona:powner:neutral', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'DE reset Owner' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [neutral: %]', r; END IF;
  IF (SELECT pp ? 'persona' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
       WHERE c.name = 'family' AND pp->>'person_id' = 'powner') THEN
    RAISE EXCEPTION 'FAIL set_person_persona [neutral als Wert gespeichert statt Key entfernt]'; END IF;
  IF agent.fn_resolve_sender(111)->>'persona' IS DISTINCT FROM 'neutral' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [nach neutral nicht neutral aufgeloest]'; END IF;

  -- ---------- fn_set_context_facts normiert Freitext-Codes (Guide-Pfad): " Butler " -> butler, "Neutral" -> Key weg ----------
  r := agent.fn_set_context_facts(jsonb_build_object('context_name', 'family',
         'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id', 'kid', 'persona', ' Butler ')))));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (SELECT pp->>'persona' FROM agent.core_contexts c,
       jsonb_array_elements(c.metadata->'facts'->'persons') pp WHERE c.name = 'family' AND pp->>'person_id' = 'kid') IS DISTINCT FROM 'butler' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [" Butler " nicht normiert: %]', r; END IF;
  r := agent.fn_set_context_facts(jsonb_build_object('context_name', 'family',
         'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id', 'kid', 'persona', 'Neutral')))));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (SELECT pp ? 'persona' FROM agent.core_contexts c,
       jsonb_array_elements(c.metadata->'facts'->'persons') pp WHERE c.name = 'family' AND pp->>'person_id' = 'kid') THEN
    RAISE EXCEPTION 'FAIL set_person_persona ["Neutral" nicht als Key-Loeschung: %]', r; END IF;

  -- ---------- unbekannte Person / ungueltiger Code / kaputte Daten ----------
  r := agent.fn_set_person_persona(jsonb_build_object('data', 'persona:nobody:butler', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'toast' IS NULL THEN
    RAISE EXCEPTION 'FAIL set_person_persona [unbekannte Person: %]', r; END IF;
  r := agent.fn_set_person_persona(jsonb_build_object('data', 'persona:kid:pirate', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unsupported_persona' THEN
    RAISE EXCEPTION 'FAIL set_person_persona [ungueltiger Code: %]', r; END IF;
  r := agent.fn_set_person_persona(jsonb_build_object('data', 'persona', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_person_persona [kaputte Daten: %]', r; END IF;

  -- ---------- unaufgeloester Absender (direkter Aufruf am Dispatcher vorbei) ----------
  r := agent.fn_set_person_persona(jsonb_build_object('data', 'persona:kid:butler', 'chat_id', '999'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_person_persona [unaufgeloester Absender: %]', r; END IF;
  IF (SELECT pp ? 'persona' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
       WHERE c.name = 'family' AND pp->>'person_id' = 'kid') THEN
    RAISE EXCEPTION 'FAIL set_person_persona [Kid trotz Ablehnung geschrieben]'; END IF;

  RAISE NOTICE 'PASS fn_set_person_persona [Owner/Mitglied-Auth, Toast-Sprache, neutral = kein Key, Ablehnungen ohne Write, resolve_sender]';
END $$;

ROLLBACK;
