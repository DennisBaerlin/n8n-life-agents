-- tests/db/core/test_fn_hitl_texts.sql
-- core.fn_hitl_texts({summary, chat_id}): die Text-Buendel des HITL-Gates je moeglichem Empfaenger.
--   * owner: Sprache des Owners, t = Gate-Chrome-Keys + alle Keys des strukturierten Summary
--     (title, note, lines[].label, Enum-Keys <enum>.<wert> lower/normalisiert)
--   * member: nur fuer eine numerische chat_id, die zu einem Nicht-Owner aufloest (Sprache + Name)
--   * liefert NIE eine chat_id (Texte entscheiden nie ueber Empfaenger)
--   * kaputtes/String-Summary wirft nicht (Chrome-Keys bleiben, Summary-Keys entfallen)
--   * languages = Code -> Eigenname (fuer kind=language)
BEGIN;

DO $$
DECLARE
  r JSONB;
  s JSONB := jsonb_build_object(
      'title', 'core.test_title',
      'note',  'core.test_note',
      'lines', jsonb_build_array(
         jsonb_build_object('label','core.test_amount','kind','money','value','12.5','currency','EUR'),
         jsonb_build_object('label','core.test_dir','kind','enum','enum','core.test_enum_dir','value','Out-Flow'),
         jsonb_build_object('label','core.test_lang','kind','language','value','ko')));
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'hitl_texts fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','P','role','owner',
                                 'birth_date','1980-01-01','language','de','telegram_user_id',111),
              jsonb_build_object('person_id','mina','first_name','Mina','last_name','Kim','role','partner',
                                 'birth_date','1985-01-01','language','ko','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;

  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.test_title', 'de', 'Titel', 'core'), ('core.test_title', 'ko', '제목', 'core'),
    ('core.test_enum_dir.out_flow', 'de', 'Ausgabe', 'core'),
    ('core.hitl.approve', 'de', 'Bestaetigen-DE', 'core'), ('core.hitl.approve', 'ko', '확인-KO', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  -- ---------- Mitglied (ko) ----------
  r := core.fn_hitl_texts(jsonb_build_object('summary', s, 'chat_id', '222'));
  IF r->'owner'->>'lang' IS DISTINCT FROM 'de' OR r->'owner'->>'locale' IS DISTINCT FROM 'de-DE' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Owner-Sprache: %]', r->'owner'; END IF;
  IF r->'member'->>'lang' IS DISTINCT FROM 'ko' OR r->'member'->>'locale' IS DISTINCT FROM 'ko-KR'
     OR r->'member'->>'name' IS DISTINCT FROM 'Mina Kim' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Member-Buendel: %]', r->'member'; END IF;
  IF r->'owner'->'t'->>'core.test_title' IS DISTINCT FROM 'Titel'
     OR r->'member'->'t'->>'core.test_title' IS DISTINCT FROM '제목' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Titel je Sprache: %]', r; END IF;
  IF r->'owner'->'t'->>'core.hitl.approve' IS DISTINCT FROM 'Bestaetigen-DE'
     OR r->'member'->'t'->>'core.hitl.approve' IS DISTINCT FROM '확인-KO' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Chrome-Key fehlt: %]', r; END IF;
  IF r->'owner'->'t'->>'core.test_enum_dir.out_flow' IS DISTINCT FROM 'Ausgabe' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Enum-Key nicht normalisiert: %]', r->'owner'->'t'; END IF;
  IF NOT (r->'owner'->'t' ? 'core.test_note') OR NOT (r->'owner'->'t' ? 'core.test_amount')
     OR NOT (r->'owner'->'t' ? 'core.hitl.hint') OR NOT (r->'owner'->'t' ? 'core.hitl.part') THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Note/Label/Hint/Teil-Key fehlt im Buendel: %]', r->'owner'->'t'; END IF;
  IF r->'languages'->>'ko' IS DISTINCT FROM '한국어' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [languages-Map: %]', r->'languages'; END IF;
  IF r::text ~ '222' OR r::text ~ '111' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Ergebnis enthaelt eine chat_id: %]', r; END IF;

  -- ---------- Owner / Test-Sentinel / Unbekannt -> kein member ----------
  r := core.fn_hitl_texts(jsonb_build_object('summary', s, 'chat_id', '111'));
  IF jsonb_typeof(r->'member') IS DISTINCT FROM 'null' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Owner bekommt member-Buendel: %]', r; END IF;
  r := core.fn_hitl_texts(jsonb_build_object('summary', s, 'chat_id', 'test_e2e'));
  IF jsonb_typeof(r->'member') IS DISTINCT FROM 'null' OR r->'owner'->>'lang' IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Sentinel: %]', r; END IF;
  r := core.fn_hitl_texts(jsonb_build_object('summary', s, 'chat_id', '999'));
  IF jsonb_typeof(r->'member') IS DISTINCT FROM 'null' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [Unbekannter als member: %]', r; END IF;

  -- ---------- String-/kaputtes Summary wirft nicht ----------
  r := core.fn_hitl_texts(jsonb_build_object('summary', 'plain text summary', 'chat_id', '111'));
  IF NOT (r->'owner'->'t' ? 'core.hitl.approve') THEN
    RAISE EXCEPTION 'FAIL hitl_texts [String-Summary: %]', r; END IF;
  r := core.fn_hitl_texts(jsonb_build_object('summary', jsonb_build_object('lines', 'kaputt'), 'chat_id', '111'));
  IF NOT (r->'owner'->'t' ? 'core.hitl.approve') THEN
    RAISE EXCEPTION 'FAIL hitl_texts [kaputtes Summary: %]', r; END IF;
  r := core.fn_hitl_texts(NULL);
  IF r->'owner'->>'lang' IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL hitl_texts [NULL-Payload: %]', r; END IF;

  RAISE NOTICE 'PASS fn_hitl_texts [Owner/Member-Sprache, Keys, Enum-Normalisierung, keine chat_id, robust]';
END $$;

ROLLBACK;
