-- tests/db/core/test_fn_ui_texts_for.sql
-- agent.fn_ui_texts_for(p) + Wrapper core.fn_ui_texts_for(p): Sprache, Locale und t-Map EINES Empfaengers fester
--   Texte (Textkatalog Phase C, Crons/Gates/Angebots-Karten). Empfaenger = Absender der chat_id, sonst Owner;
--   eine kaputte/nicht-numerische/unbekannte chat_id faellt auf den Owner (nie ein RAISE: fail-open-Gates
--   haengen daran). Keys = p.keys + jeder key-foermige String in p.doc (+ enum-Wert-Keys). Nie eine chat_id im Ergebnis.
BEGIN;

DO $$
DECLARE
  r JSONB;
  v_def boolean;
  v_cfg text[];
  v_c   text;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'ui_texts_for fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','P','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111),
              jsonb_build_object('person_id','mina','first_name','Mina','last_name','P','role','partner',
                                 'birth_date','1985-01-01','language','ko','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;

  DELETE FROM core.ui_texts WHERE key LIKE 'core.zz.%';
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || k, 'core'
    FROM unnest(ARRAY['core.zz.a', 'core.zz.b', 'core.zz.c', 'core.zz.enum.x_y']) k,
         unnest(ARRAY['de', 'en', 'ko']) l;
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('core.zz.only_en', 'en', 'EN only', 'core');

  -- Absender (Mitglied) -> seine Sprache
  r := agent.fn_ui_texts_for(jsonb_build_object('chat_id', '222', 'keys', jsonb_build_array('core.zz.a')));
  IF r->>'lang' IS DISTINCT FROM 'ko' OR r->>'locale' IS DISTINCT FROM 'ko-KR' OR r->'t'->>'core.zz.a' IS DISTINCT FROM 'KO:core.zz.a' THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Mitglied ko: %]', r; END IF;
  -- Owner-chat_id (auch als Zahl) -> Owner-Sprache
  r := agent.fn_ui_texts_for(jsonb_build_object('chat_id', 111, 'keys', jsonb_build_array('core.zz.a')));
  IF r->>'lang' IS DISTINCT FROM 'de' OR r->'t'->>'core.zz.a' IS DISTINCT FROM 'DE:core.zz.a' THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Owner: %]', r; END IF;
  -- nichts / nicht numerisch / unbekannt / ueberlang -> Owner, nie ein RAISE
  FOREACH v_c IN ARRAY ARRAY['none', 'abc', '99999', '1234567890123456789012', '-5'] LOOP
    r := agent.fn_ui_texts_for(CASE WHEN v_c = 'none' THEN jsonb_build_object('keys', jsonb_build_array('core.zz.a'))
                                    ELSE jsonb_build_object('chat_id', v_c, 'keys', jsonb_build_array('core.zz.a')) END);
    IF r->>'lang' IS DISTINCT FROM 'de' THEN
      RAISE EXCEPTION 'FAIL ui_texts_for [% -> Owner erwartet: %]', v_c, r; END IF;
  END LOOP;
  -- NULL / Nicht-Objekt -> Owner, leere t-Map
  r := agent.fn_ui_texts_for(NULL);
  IF r->>'lang' IS DISTINCT FROM 'de' OR r->'t' IS DISTINCT FROM '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [NULL: %]', r; END IF;
  r := agent.fn_ui_texts_for('"x"'::jsonb);
  IF r->>'lang' IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Nicht-Objekt: %]', r; END IF;

  -- Keys aus dem Dokument (verschachtelte tpl-Parameter + enum-Wert-Key) zusaetzlich zu p.keys
  r := agent.fn_ui_texts_for(jsonb_build_object('chat_id', '222', 'keys', jsonb_build_array('core.zz.a'),
         'doc', jsonb_build_object('alerts', jsonb_build_array(jsonb_build_object(
           'msg', jsonb_build_array(jsonb_build_object('kind','tpl','value','core.zz.b',
             'params', jsonb_build_object('n', jsonb_build_object('kind','key','value','core.zz.c'),
                                          'e', jsonb_build_object('kind','enum','enum','core.zz.enum','value','X Y')))))))));
  IF r->'t'->>'core.zz.b' IS DISTINCT FROM 'KO:core.zz.b' OR r->'t'->>'core.zz.c' IS DISTINCT FROM 'KO:core.zz.c'
     OR r->'t'->>'core.zz.enum.x_y' IS DISTINCT FROM 'KO:core.zz.enum.x_y' OR NOT (r->'t' ? 'core.zz.a') THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Keys aus doc: %]', r; END IF;
  -- Fallback: Sprache -> en -> Key selbst
  r := agent.fn_ui_texts_for(jsonb_build_object('chat_id', '222', 'keys', jsonb_build_array('core.zz.only_en', 'core.zz.missing')));
  IF r->'t'->>'core.zz.only_en' IS DISTINCT FROM 'EN only' OR r->'t'->>'core.zz.missing' IS DISTINCT FROM 'core.zz.missing' THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Fallback: %]', r; END IF;
  -- SICHERHEIT: genau {lang, language, language_label, locale, t}, nie eine chat_id/Person
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r) k) IS DISTINCT FROM ARRAY['lang', 'language', 'language_label', 'locale', 't'] THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Rueckgabe-Form: %]', r; END IF;
  -- Prompt-Label (EINE Adresse fuer "schreibe in ko (한국어)"): Code + Eigenname in Klammern, ohne Namen nur der Code
  IF r->>'language_label' IS DISTINCT FROM (r->>'lang') || COALESCE(' (' || (r->>'language') || ')', '') OR r->>'lang' IS DISTINCT FROM 'ko' THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [language_label: %]', r; END IF;

  -- Wrapper: dasselbe Ergebnis, SECURITY DEFINER mit gepinntem search_path (pg_temp zuletzt), kein PUBLIC-EXECUTE
  IF core.fn_ui_texts_for(jsonb_build_object('chat_id', '222', 'keys', jsonb_build_array('core.zz.a')))
     IS DISTINCT FROM agent.fn_ui_texts_for(jsonb_build_object('chat_id', '222', 'keys', jsonb_build_array('core.zz.a'))) THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Wrapper weicht ab]'; END IF;
  SELECT p.prosecdef, p.proconfig INTO v_def, v_cfg FROM pg_proc p
   WHERE p.oid = 'core.fn_ui_texts_for(jsonb)'::regprocedure;
  IF NOT v_def OR v_cfg IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp'] THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [Wrapper-Haertung: definer=% config=%]', v_def, v_cfg; END IF;
  IF has_function_privilege('public', 'core.fn_ui_texts_for(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL ui_texts_for [PUBLIC darf den Wrapper ausfuehren]'; END IF;

  RAISE NOTICE 'PASS fn_ui_texts_for [Mitglied/Owner/kaputte chat_id -> Owner, Keys aus doc, Fallback, Form, Wrapper-Haertung]';
END $$;

ROLLBACK;
