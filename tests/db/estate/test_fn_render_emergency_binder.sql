-- tests/db/estate/test_fn_render_emergency_binder.sql
-- WS-5: die druckbare Notfallmappe (groesster PII-Egress). Prueft: adults_only-Backstop IN der fn
-- (Kind -> RAISE, auch bei Direkt-Aufruf), Druck-Header, Maskierung AN/AUS (Steuer-ID + RV-Nr.),
-- System-Steckbrief-Sektion, finance-Absenz graceful. Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_txt    TEXT;
  v_raised BOOLEAN := FALSE;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','kid','first_name','Kim','last_name','Beispiel',
                                 'role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  INSERT INTO estate.person_records (person_id, tax_id, pension_insurance_no, employer)
  VALUES ('erika', '12345678901', '12190680M007', 'Beispiel AG');
  INSERT INTO estate.system_profile (scope, backup_key_location, system_location)
  VALUES ('household', 'Umschlag im Tresor Büro', 'Debian-LXC im Keller');

  -- ---------- TEST 1: adults_only-Backstop IN der fn (Kind -> RAISE) ----------
  BEGIN
    v_txt := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','333'));
  EXCEPTION WHEN insufficient_privilege THEN v_raised := TRUE;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL [1 Kind erhielt die Voll-PII-Mappe (kein RAISE)]'; END IF;
  RAISE NOTICE 'PASS [1] adults_only-Backstop in der fn (Kind -> RAISE, entkoppelt vom Tool-Gate)';

  -- ---------- TEST 2: Druck-Header + unmaskiert (Owner, Default) -> echte Kennnummern ----------
  v_txt := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','111'));
  IF v_txt IS NULL OR v_txt NOT LIKE '%estate.binder.title%' OR v_txt NOT LIKE '%estate.binder.as_of: %' THEN
    RAISE EXCEPTION 'FAIL [2 Druck-Header fehlt]: %', left(COALESCE(v_txt,'NULL'), 120); END IF;
  IF v_txt NOT LIKE '%estate.binder.full%' THEN
    RAISE EXCEPTION 'FAIL [2 Vollständig-Hinweis fehlt bei mask=off]'; END IF;
  IF v_txt NOT LIKE '%12345678901%' OR v_txt NOT LIKE '%12190680M007%' THEN
    RAISE EXCEPTION 'FAIL [2 unmaskiert: Steuer-ID/RV-Nr. fehlen]: %', v_txt; END IF;
  RAISE NOTICE 'PASS [2] Header + unmaskierte Kennnummern (Default für den Partner)';

  -- ---------- TEST 3: Maskierung AN -> Steuer-ID + RV-Nr. redigiert ----------
  v_txt := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','111', 'mask_sensitive', true));
  IF v_txt LIKE '%12345678901%' OR v_txt LIKE '%12190680M007%' THEN
    RAISE EXCEPTION 'FAIL [3 Maskierung liess Kennnummern durch]: %', v_txt; END IF;
  IF v_txt NOT LIKE '%••••••%' THEN
    RAISE EXCEPTION 'FAIL [3 Masken-Platzhalter fehlt]: %', v_txt; END IF;
  IF v_txt NOT LIKE '%estate.binder.masked%' THEN
    RAISE EXCEPTION 'FAIL [3 Maskiert-Hinweis fehlt bei mask=on]'; END IF;
  RAISE NOTICE 'PASS [3] Maskierung AN: Steuer-ID/RV-Nr. -> ••••••';

  -- ---------- TEST 4: System-Steckbrief-Sektion (backup_key-Fundort, nie das Geheimnis) ----------
  v_txt := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','111'));
  IF v_txt NOT LIKE '%estate.register.system%' OR v_txt NOT LIKE '%Umschlag im Tresor Büro%' THEN
    RAISE EXCEPTION 'FAIL [4 System-Steckbrief-Sektion fehlt]: %', v_txt; END IF;
  RAISE NOTICE 'PASS [4] System-Steckbrief-Sektion (backup_key-FUNDORT)';

  -- ---------- TEST 5: finance-Absenz graceful (im db_test-Substrat nicht registriert) ----------
  IF v_txt NOT LIKE '%estate.register.fin_absent%' THEN
    RAISE EXCEPTION 'FAIL [5 finance-Absenz-Zeile fehlt / Crash]: %', v_txt; END IF;
  RAISE NOTICE 'PASS [5] finance-Absenz graceful (kein Crash, sichtbare Zeile)';

  -- ---------- TEST 6: mask_sensitive='' (LLM-Weglassung -> 4-arg-$fromAI-Default) -> kein Cast-Crash ----------
  v_txt := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','111', 'mask_sensitive', ''));
  IF v_txt IS NULL OR v_txt NOT LIKE '%12345678901%' THEN
    RAISE EXCEPTION 'FAIL [6 mask_sensitive='''' crasht/maskiert statt Default false]: %', left(COALESCE(v_txt,'NULL'),80); END IF;
  RAISE NOTICE 'PASS [6] mask_sensitive='''' -> Default false (NULLIF-Guard, kein boolean-Cast-Crash)';

  -- ---------- TEST 7 (Textkatalog Phase C): Sprache der ANFORDERNDEN Person, Datum im Sprachmuster ----------
  -- Partner Mina (ko) fordert an -> koreanischer Kopf + Datum YYYY. MM. DD.; der Owner (de) bekommt deutsch.
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}',
         (metadata->'facts'->'persons') || jsonb_build_array(jsonb_build_object('person_id','mina','first_name','Mina',
           'last_name','Beispiel','role','partner','birth_date','1985-01-01','language','ko','telegram_user_id',222)))
   WHERE name = 'family';
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,0,language}', '"de"') WHERE name = 'family';
  UPDATE core.ui_languages SET date_pattern = CASE code WHEN 'de' THEN 'DD.MM.YYYY' WHEN 'ko' THEN 'YYYY. MM. DD.' ELSE date_pattern END;
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('estate.binder.title', 'de', 'Notfallmappe', 'estate'), ('estate.binder.title', 'ko', '비상 파일', 'estate'),
    ('estate.register.system', 'ko', 'KO-SYSTEM', 'estate')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  v_txt := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','222'));
  IF v_txt NOT LIKE '# 비상 파일%' OR v_txt NOT LIKE '%' || to_char(current_date, 'YYYY. MM. DD.') || '%' OR v_txt NOT LIKE '%KO-SYSTEM%' THEN
    RAISE EXCEPTION 'FAIL [7 ko-Anfrager bekommt nicht ko (Kopf/Datum/Body)]: %', left(v_txt, 200); END IF;
  v_txt := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','111'));
  IF v_txt NOT LIKE '# Notfallmappe%' OR v_txt NOT LIKE '%' || to_char(current_date, 'DD.MM.YYYY') || '%' THEN
    RAISE EXCEPTION 'FAIL [7 Owner (de) bekommt nicht de]: %', left(v_txt, 200); END IF;
  RAISE NOTICE 'PASS [7] Sprache des Anfragenden (ko/de) inkl. Datum im Sprachmuster';
END $$;

ROLLBACK;
