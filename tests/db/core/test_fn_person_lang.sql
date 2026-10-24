-- tests/db/core/test_fn_person_lang.sql
-- agent.fn_person_lang(person_id): Sprache + Intl-Locale eines Empfaengers fester Texte.
--   Fallback-Kette: Person -> Owner -> 'en'; ein (nicht mehr) unterstuetzter Code faellt ebenfalls zurueck.
--   person_id NULL -> Owner-Sprache.
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'person_lang fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','P','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111),
              jsonb_build_object('person_id','mina','first_name','Mina','last_name','P','role','partner',
                                 'birth_date','1985-01-01','language','ko','telegram_user_id',222),
              jsonb_build_object('person_id','kid','first_name','Kid','last_name','P','role','child',
                                 'birth_date','2015-01-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;

  r := agent.fn_person_lang('mina');
  IF r->>'lang' IS DISTINCT FROM 'ko' OR r->>'locale' IS DISTINCT FROM 'ko-KR' THEN
    RAISE EXCEPTION 'FAIL person_lang [eigene Sprache: %]', r; END IF;
  r := agent.fn_person_lang('kid');
  IF r->>'lang' IS DISTINCT FROM 'de' OR r->>'locale' IS DISTINCT FROM 'de-DE' THEN
    RAISE EXCEPTION 'FAIL person_lang [Fallback Owner: %]', r; END IF;
  r := agent.fn_person_lang(NULL);
  IF r->>'lang' IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL person_lang [NULL -> Owner: %]', r; END IF;
  r := agent.fn_person_lang('nobody');
  IF r->>'lang' IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL person_lang [unbekannte Person -> Owner: %]', r; END IF;

  -- Owner ohne Sprache -> 'en' (Telegram-Empfehlung "last recorded tag or English")
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,0}',
         (metadata->'facts'->'persons'->0) - 'language') WHERE name = 'family';
  r := agent.fn_person_lang('kid');
  IF r->>'lang' IS DISTINCT FROM 'en' OR r->>'locale' IS DISTINCT FROM 'en-GB' THEN
    RAISE EXCEPTION 'FAIL person_lang [Fallback en: %]', r; END IF;

  -- ein nicht mehr gelisteter Code (Sprache entfernt) faellt zurueck statt zu brechen
  ALTER TABLE agent.core_contexts DISABLE TRIGGER trg_validate_household_facts;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,1,language}', '"fr"')
   WHERE name = 'family';
  ALTER TABLE agent.core_contexts ENABLE TRIGGER trg_validate_household_facts;
  r := agent.fn_person_lang('mina');
  IF r->>'lang' IS DISTINCT FROM 'en' THEN
    RAISE EXCEPTION 'FAIL person_lang [unbekannter Code faellt nicht zurueck: %]', r; END IF;

  RAISE NOTICE 'PASS fn_person_lang [Person, Owner-Fallback, en-Fallback, unbekannter Code]';
END $$;

ROLLBACK;
