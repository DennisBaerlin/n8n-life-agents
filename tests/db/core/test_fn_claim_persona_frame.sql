-- tests/db/core/test_fn_claim_persona_frame.sql
-- agent.fn_claim_persona_frame(p): Rahmensatz vor einer Spezialisten-Antwort.
--   * nur Persona != neutral, Signal FRAME, Spezialisten-Teile vorhanden
--   * erste solche Antwort des lokalen Tages = Tagesgruss (greet.<persona>.<fn_daypart()>) mit Vornamen, einmal je Tag
--   * sonst Rahmensatz frame.<persona>.* nach message_id % Anzahl (Rotation ueber alle 7), {name} -> Vorname
--   * fehlender Gruss-Key -> Rahmensatz, kein Latch; Sprache der Person, sonst en, nie gemischt
--   * alte Gruss-Latches der Person weg (split_part, kein LIKE); unbekannter Absender -> null
-- Die Texte legt der Test selbst an (unabhaengig vom Katalog-Seed).
-- Ein fehlender Vorname ist ueber family nicht herstellbar (Validator verlangt first_name); die fn behandelt ihn trotzdem.
BEGIN;

DO $$
DECLARE
  i int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'claim_persona_frame fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Erika','last_name','Mustermann','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111,'persona','butler'),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel','role','partner',
                                 'birth_date','1985-01-01','language','ko','telegram_user_id',222,'persona','butler'),
              jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','Mustermann','role','child',
                                 'birth_date','2012-01-01','language','de','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;
  DELETE FROM core.notification_state WHERE source = 'persona_greet';
  DELETE FROM core.ui_texts WHERE key LIKE 'core.persona.frame.butler.%' OR key LIKE 'core.persona.greet.butler.%';
  FOR i IN 1..7 LOOP
    INSERT INTO core.ui_texts (key, lang, text, package) VALUES
      ('core.persona.frame.butler.' || i, 'de', '🎩 F' || i || CASE WHEN i = 3 THEN ' {name}' ELSE '' END, 'core'),
      ('core.persona.frame.butler.' || i, 'en', '🎩 E' || i, 'core');
  END LOOP;
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT 'core.persona.greet.butler.' || d, 'de', '🎩 G-' || d || ', {name}.', 'core'
    FROM unnest(ARRAY['morning', 'day', 'evening', 'night']) d;
END $$;

DO $$
DECLARE
  r       jsonb;
  i       int;
  v_seen  text[] := ARRAY[]::text[];
BEGIN
  -- ---------- Bedingungen: neutral, NOFRAME, keine Teile, unbekannter Absender ----------
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '333', 'signal', 'FRAME', 'has_parts', true, 'message_id', 1));
  IF r->>'text' IS NOT NULL OR (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL persona_frame [neutral: %]', r; END IF;
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '111', 'signal', 'NOFRAME', 'has_parts', true, 'message_id', 1));
  IF r->>'text' IS NOT NULL THEN RAISE EXCEPTION 'FAIL persona_frame [NOFRAME: %]', r; END IF;
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '111', 'signal', 'FRAME', 'has_parts', false, 'message_id', 1));
  IF r->>'text' IS NOT NULL THEN RAISE EXCEPTION 'FAIL persona_frame [ohne Teile: %]', r; END IF;
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '999', 'signal', 'FRAME', 'has_parts', true, 'message_id', 1));
  IF r->>'text' IS NOT NULL THEN RAISE EXCEPTION 'FAIL persona_frame [unbekannter Absender: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'persona_greet') THEN
    RAISE EXCEPTION 'FAIL persona_frame [Latch ohne Gruss gesetzt]'; END IF;

  -- ---------- Tagesgruss: einmal je Tag, mit Vornamen; alte Latches der Person weg, fremde bleiben ----------
  INSERT INTO core.notification_state (source, key, state) VALUES
    ('persona_greet', 'powner:2026-01-01', 'fired'), ('persona_greet', 'powner_x:2026-01-01', 'fired');
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '111', 'signal', 'frame', 'has_parts', true, 'message_id', 1));
  IF r->>'text' IS DISTINCT FROM '🎩 G-' || core.fn_daypart() || ', Erika.' THEN
    RAISE EXCEPTION 'FAIL persona_frame [Tagesgruss: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'persona_greet' AND key = 'powner:2026-01-01')
     OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'persona_greet' AND key = 'powner_x:2026-01-01')
     OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'persona_greet' AND key = 'powner:' || core.fn_today()) THEN
    RAISE EXCEPTION 'FAIL persona_frame [Latch-Pflege]'; END IF;

  -- ---------- danach Rahmensaetze: Rotation ueber alle 7 (Schrittweite 1), {name} ersetzt ----------
  FOR i IN 0..6 LOOP
    r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '111', 'signal', 'FRAME', 'has_parts', true, 'message_id', 700 + i));
    v_seen := v_seen || (r->>'text');
  END LOOP;
  IF (SELECT count(DISTINCT x) FROM unnest(v_seen) x) <> 7 OR NOT ('🎩 F3 Erika' = ANY (v_seen))
     OR EXISTS (SELECT 1 FROM unnest(v_seen) x WHERE x LIKE '%{name}%' OR x LIKE '🎩 E%' OR x LIKE '%G-%') THEN
    RAISE EXCEPTION 'FAIL persona_frame [Rotation/Name/Sprache: %]', v_seen; END IF;
  -- Schrittweite 2 (aufeinanderfolgende Nachrichten-IDs von Nutzer + Bot) trifft ebenfalls alle 7
  v_seen := ARRAY[]::text[];
  FOR i IN 0..6 LOOP
    r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '111', 'signal', 'FRAME', 'has_parts', true, 'message_id', 800 + 2 * i));
    v_seen := v_seen || (r->>'text');
  END LOOP;
  IF (SELECT count(DISTINCT x) FROM unnest(v_seen) x) <> 7 THEN
    RAISE EXCEPTION 'FAIL persona_frame [Schrittweite 2: %]', v_seen; END IF;

  -- ---------- Sprache ko ohne ko-Texte -> en; ohne en-Gruss -> Rahmensatz, kein Latch ----------
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '222', 'signal', 'FRAME', 'has_parts', true, 'message_id', 3));
  IF r->>'text' IS DISTINCT FROM '🎩 E4' THEN RAISE EXCEPTION 'FAIL persona_frame [en-Fallback ohne Gruss-Key: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'persona_greet' AND split_part(key, ':', 1) = 'lena') THEN
    RAISE EXCEPTION 'FAIL persona_frame [Latch trotz fehlendem Gruss]'; END IF;

  -- ---------- keine Rahmensaetze -> null ----------
  DELETE FROM core.ui_texts WHERE key LIKE 'core.persona.frame.butler.%';
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', '222', 'signal', 'FRAME', 'has_parts', true, 'message_id', 3));
  IF r->>'text' IS NOT NULL OR (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL persona_frame [ohne Katalog: %]', r; END IF;
  r := agent.fn_claim_persona_frame(jsonb_build_object('chat_id', 'kaputt', 'signal', 'FRAME', 'has_parts', true));
  IF r->>'text' IS NOT NULL THEN RAISE EXCEPTION 'FAIL persona_frame [kaputte chat_id: %]', r; END IF;

  RAISE NOTICE 'PASS fn_claim_persona_frame [Bedingungen, Tagesgruss einmal je Tag, Rotation ueber 7, Sprache, Rueckfall]';
END $$;

ROLLBACK;
