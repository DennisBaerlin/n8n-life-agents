-- tests/db/career/test_fn_handle_job_feedback.sql
-- career.fn_handle_job_feedback: Callback-State-Machine (up/down), Re-Tap idempotent, Flip, feedback_at,
-- unbekannte id/Aktion -> {ok:false} OHNE RAISE. Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  r jsonb; v_id bigint; v_kid_id bigint; v_status text; v_fb timestamptz;
BEGIN
  -- P2a-Fixture: family owner(erika 111) + partner(lena 222) + Kind(kim 333, erwerbsfaehig) -> agent.persons;
  -- der Treffer gehoert erika; das Kind bekommt einen EIGENEN Treffer (D4 career-own-card inkl. Kind).
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'language','de','as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                           'birth_date','1985-06-21','telegram_user_id',222,'language','ko','as_of','2026-06-11'),
        jsonb_build_object('person_id','kim','first_name','Kim','last_name','M','role','child',
                           'birth_date','2010-03-10','telegram_user_id',333,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  -- Katalog-Fixture: Text = Sprach-Marker + Key (Toast in der Sprache des Tippenden, Textkatalog §3.11).
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || k, split_part(k, '.', 1)
  FROM unnest(ARRAY['core.toast.unresolved_sender','career.toast.job_up','career.toast.job_down',
                    'career.toast.job_not_found']) k
  CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  INSERT INTO career.job_matches (person_id, source, external_id, title, score)
  VALUES ('erika','bundesagentur','REF1','Scrum Master',3) RETURNING id INTO v_id;
  INSERT INTO career.job_matches (person_id, source, external_id, title, score)
  VALUES ('kim','bundesagentur','REFKID','Ferienjob',2) RETURNING id INTO v_kid_id;

  -- TEST 1 (B3 Owner-Happy-Path): erika (chat_id=111, Eigentuemerin) 👍 -> interested + feedback_at + toast + ok:true
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:up:'||v_id::text,'chat_id',111,'callback_id','cb1'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1]: %', r; END IF;
  IF r->>'toast' IS DISTINCT FROM 'DE:career.toast.job_up' THEN RAISE EXCEPTION 'FAIL [1] toast (Owner-Sprache de): %', r; END IF;
  SELECT status, feedback_at INTO v_status, v_fb FROM career.job_matches WHERE id=v_id;
  IF v_status <> 'interested' THEN RAISE EXCEPTION 'FAIL [1] status=%', v_status; END IF;
  IF v_fb IS NULL THEN RAISE EXCEPTION 'FAIL [1] feedback_at null'; END IF;
  RAISE NOTICE 'PASS [1] Owner-Tap (chat_id=111) -> interested + feedback_at + toast';

  -- TEST 2: Flip 👎 -> dismissed (Eigentuemerin)
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:down:'||v_id::text,'chat_id',111));
  SELECT status INTO v_status FROM career.job_matches WHERE id=v_id;
  IF v_status <> 'dismissed' THEN RAISE EXCEPTION 'FAIL [2] flip status=%', v_status; END IF;
  RAISE NOTICE 'PASS [2] flip down -> dismissed';

  -- TEST 3: Re-Tap idempotent (up zweimal -> interested, ok:true)
  PERFORM career.fn_handle_job_feedback(jsonb_build_object('data','job:up:'||v_id::text,'chat_id',111));
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:up:'||v_id::text,'chat_id',111));
  SELECT status INTO v_status FROM career.job_matches WHERE id=v_id;
  IF v_status <> 'interested' THEN RAISE EXCEPTION 'FAIL [3] idempotent status=%', v_status; END IF;
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [3]: %', r; END IF;
  RAISE NOTICE 'PASS [3] re-tap idempotent';

  -- TEST 4: unbekannte id (Sender aufloesbar) -> {ok:false, job match not found}, KEIN RAISE
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:up:999999999','chat_id',111));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4] unknown id: %', r; END IF;
  IF r->>'reason' IS DISTINCT FROM 'job match not found' THEN RAISE EXCEPTION 'FAIL [4] reason: %', r; END IF;
  RAISE NOTICE 'PASS [4] unknown id -> ok:false (no RAISE)';

  -- TEST 5: unbekannte Aktion / ungueltige id -> {ok:false} (vor der Sender-Aufloesung)
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:weird:'||v_id::text));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5 action]: %', r; END IF;
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:up:abc'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5 id]: %', r; END IF;
  RAISE NOTICE 'PASS [5] unknown action / invalid id -> ok:false';

  -- TEST 6 (P2a Eigentuemer-Check): FREMDE Person (lena, chat_id=222) tippt auf erikas Treffer -> {ok:false},
  -- KEIN Write (status bleibt 'interested' aus Test 3). Gleiche Antwort wie nicht-existent (kein Enumeration-Leak).
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:down:'||v_id::text,'chat_id',222));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6] fremder Sender konnte bewerten: %', r; END IF;
  IF r->>'reason' IS DISTINCT FROM 'job match not found' THEN RAISE EXCEPTION 'FAIL [6] reason (kein Leak): %', r; END IF;
  IF r->>'toast' IS DISTINCT FROM 'KO:career.toast.job_not_found' THEN RAISE EXCEPTION 'FAIL [6] Toast in Lenas Sprache ko: %', r; END IF;
  SELECT status INTO v_status FROM career.job_matches WHERE id=v_id;
  IF v_status <> 'interested' THEN RAISE EXCEPTION 'FAIL [6] fremder Tap aenderte den Status auf %', v_status; END IF;
  RAISE NOTICE 'PASS [6] Eigentuemer-Check (fremder Sender -> ok:false, kein Write, kein Leak)';

  -- TEST 7 (B1 unaufloesbarer/junk Sender -> {ok:false}, KEIN RAISE)
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:up:'||v_id::text));   -- kein chat_id
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unresolved sender' THEN
    RAISE EXCEPTION 'FAIL [7a] fehlender chat_id soll unresolved sender: %', r; END IF;
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:up:'||v_id::text,'chat_id','abc'));  -- nicht-numerisch
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unresolved sender' THEN
    RAISE EXCEPTION 'FAIL [7b] nicht-numerischer chat_id soll RAISE-frei unresolved sender: %', r; END IF;
  RAISE NOTICE 'PASS [7] unaufloesbarer/junk chat_id -> ok:false (kein RAISE)';

  -- TEST 8 (D4 career-own-card inkl. Kind): das Kind (333) bewertet seine EIGENE Karte -> ok (nur Eigentum,
  -- KEIN adults_only im job-Handler; ein erwerbsfaehiges Kind an eigenen Daten, low-stakes). Gegenprobe: das
  -- Kind an erikas FREMDER Karte -> NOT FOUND (Eigentum, kein Leak).
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:up:'||v_kid_id::text,'chat_id',333));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [8] Kind konnte EIGENE Karte nicht bewerten: %', r; END IF;
  SELECT status INTO v_status FROM career.job_matches WHERE id=v_kid_id;
  IF v_status <> 'interested' THEN RAISE EXCEPTION 'FAIL [8] Kind-eigene-Karte status=%', v_status; END IF;
  r := career.fn_handle_job_feedback(jsonb_build_object('data','job:down:'||v_id::text,'chat_id',333));  -- erikas Karte
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'job match not found' THEN
    RAISE EXCEPTION 'FAIL [8] Kind an fremder Karte nicht geblockt: %', r; END IF;
  RAISE NOTICE 'PASS [8] Kind bewertet EIGENE Karte -> ok; fremde Karte -> not found (Eigentum)';
END $$;
ROLLBACK;
