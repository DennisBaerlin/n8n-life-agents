-- tests/db/core/test_fn_claim_next_step_offer.sql
-- core.fn_claim_next_step_offer(p) + core.fn_next_step_offer_keys + Feld offer von core.fn_get_next_step:
--   Owner-Entscheid 2026-11-11 "1x/Tag, nach 3x Ruhe": Gruss/Lebenszeichen hoechstens offer_per_day je Kalendertag,
--   derselbe Schritt in derselben Lage hoechstens offer_max_repeats ohne gueltigen Tipp; "und jetzt?" (smalltalk NULL)
--   wird weder geprueft noch gezaehlt; beide Grenzen werden erst gelesen, dann zusammen gesetzt (kein verbrauchter Latch
--   ohne Knopf); neue Generation = frische Zaehlung; 0 = aus; offer (lesend) und Claim nutzen dieselben Keys.
BEGIN;

DO $$
DECLARE
  v_order jsonb := '["core:household"]';
  s jsonb;
  ok boolean;
  i int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  UPDATE agent.guide_onboarding_state SET status = 'unknown' WHERE section_key = 'household';
  DELETE FROM core.notification_state WHERE source IN ('next_step_day', 'next_step_offer');
  DELETE FROM core.config WHERE package = 'core' AND category = 'next_step';

  -- ---------- (1) frisch: offer true; Claim true; danach offer false (1x/Tag) ----------
  s := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'smalltalk', 'greeting'));
  IF (s->>'offer')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 frisch offer]: %', s; END IF;
  ok := core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                         'generation', s->'generation', 'smalltalk', 'greeting'));
  IF ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 Claim]'; END IF;
  s := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'smalltalk', 'ping'));
  IF (s->>'offer')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 zweiter Gruss am Tag]: %', s; END IF;
  IF core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                      'generation', s->'generation', 'smalltalk', 'ping')) THEN
    RAISE EXCEPTION 'FAIL [1 zweiter Claim am Tag]'; END IF;

  -- ---------- (2) "und jetzt?" (smalltalk NULL): immer, zaehlt nicht ----------
  s := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order));
  IF (s->>'offer')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [2 und jetzt offer]: %', s; END IF;
  IF NOT core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                          'generation', s->'generation')) THEN
    RAISE EXCEPTION 'FAIL [2 und jetzt Claim]'; END IF;
  IF (SELECT count(*) FROM core.notification_state WHERE source = 'next_step_offer') <> 1 THEN
    RAISE EXCEPTION 'FAIL [2 und jetzt hat gezaehlt]'; END IF;

  -- ---------- (3) 3x je Schritt: Tag-Grenze aus, dann genau beim 4. Mal Ruhe; Tag-Key bleibt dabei frei ----------
  INSERT INTO core.config (category, key, value, package, value_type, minimum) VALUES ('next_step', 'offer_per_day', '0', 'core', 'integer', 0);
  FOR i IN 2..3 LOOP
    IF NOT core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                            'generation', s->'generation', 'smalltalk', 'greeting')) THEN
      RAISE EXCEPTION 'FAIL [3 Claim %]', i; END IF;
  END LOOP;
  s := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'smalltalk', 'greeting'));
  IF (s->>'offer')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 nach 3x offer]: %', s; END IF;
  UPDATE core.config SET value = '1' WHERE category = 'next_step' AND key = 'offer_per_day';
  DELETE FROM core.notification_state WHERE source = 'next_step_day';
  IF core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                      'generation', s->'generation', 'smalltalk', 'greeting')) THEN
    RAISE EXCEPTION 'FAIL [3 Claim nach 3x]'; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'next_step_day' AND state = 'fired') THEN
    RAISE EXCEPTION 'FAIL [3 Tag-Key verbraucht ohne Knopf]'; END IF;

  -- ---------- (4) neue Generation (Lage-Aenderung, auch Rueckkehr) -> frische Zaehlung ----------
  IF NOT core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                          'generation', (s->>'generation')::bigint + 1, 'smalltalk', 'greeting')) THEN
    RAISE EXCEPTION 'FAIL [4 neue Generation]'; END IF;

  -- ---------- (5) 0 = aus: keine Grenze ----------
  UPDATE core.config SET value = '0' WHERE category = 'next_step' AND key = 'offer_per_day';
  INSERT INTO core.config (category, key, value, package, value_type, minimum) VALUES ('next_step', 'offer_max_repeats', '0', 'core', 'integer', 0);
  s := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'smalltalk', 'greeting'));
  IF (s->>'offer')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5 aus offer]: %', s; END IF;
  IF NOT core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                          'generation', s->'generation', 'smalltalk', 'greeting')) THEN
    RAISE EXCEPTION 'FAIL [5 aus Claim]'; END IF;

  -- ---------- (6) Keys: Kalendertag + Index, Lage + Generation + Zaehler ----------
  DELETE FROM core.config WHERE package = 'core' AND category = 'next_step';
  s := core.fn_next_step_offer_keys('erika', 'onboarding:core:household', 'open', 42);
  IF s->'day' <> jsonb_build_array('erika:' || to_char(core.fn_today(), 'YYYY-MM-DD') || ':1')
     OR jsonb_array_length(s->'repeat') <> 3 OR s->'repeat'->>2 <> 'erika:onboarding:core:household:open:42:3' THEN
    RAISE EXCEPTION 'FAIL [6 Keys]: %', s; END IF;

  -- ---------- (7) unbekannter Absender / Fehler -> false (kein Knopf) ----------
  IF core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '999', 'callback', 'x', 'smalltalk', 'greeting')) THEN
    RAISE EXCEPTION 'FAIL [7 unbekannt]'; END IF;
  IF core.fn_claim_next_step_offer('{}'::jsonb) THEN RAISE EXCEPTION 'FAIL [7 leer]'; END IF;

  RAISE NOTICE 'PASS test_fn_claim_next_step_offer (1x/Tag, und jetzt frei, 3x je Lage, atomar, Generation, 0 = aus, Keys, fail-closed)';
END $$;

ROLLBACK;
