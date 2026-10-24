-- tests/db/career/test_fn_record_job_match.sql
-- career.fn_record_job_match: Multi-Source-UPSERT (partial-unique (source, external_id, person_id)),
-- forwarded-INSERT, korrigierbare Ablehnung, Post-State, board-Speicherung. Self-contained (BEGIN..ROLLBACK).
-- V005: refnr->external_id, source-skopierte Identitaet, +board, source-Whitelist {bundesagentur,adzuna,jsearch,forwarded}.
BEGIN;
DO $$
DECLARE
  r jsonb; r2 jsonb;
  v_id bigint; v_cnt int; v_title text; v_pid text; v_board text;
BEGIN
  -- P2a-Fixture: family owner(erika 111) + partner(lena 222) -> agent.persons (FK-Ziel) + Owner-Fallback.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                           'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- TEST 1: bundesagentur-INSERT mit external_id+score -> created=true, score=3, job_match_id
  r := career.fn_record_job_match(jsonb_build_object(
    'source','bundesagentur','external_id','10000-ABC-S','title','Scrum Master','employer','ACME',
    'location','Hamburg','score',3,'score_reasoning','passt','raw', jsonb_build_object('plz','20095')));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1]: %', r; END IF;
  IF (r->>'created')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1] created: %', r; END IF;
  IF (r->>'score')::int IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'FAIL [1] score: %', r; END IF;
  v_id := (r->>'job_match_id')::bigint;
  IF v_id IS NULL THEN RAISE EXCEPTION 'FAIL [1] job_match_id null'; END IF;
  -- board bleibt NULL fuer bundesagentur (Direkt-Feed, kein Board)
  SELECT board INTO v_board FROM career.job_matches WHERE id = v_id;
  IF v_board IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1] bundesagentur board should be NULL, got %', v_board; END IF;
  RAISE NOTICE 'PASS [1] bundesagentur INSERT (created, score, id, board NULL)';

  -- TEST 2: UPSERT derselben (source, external_id) (Re-Scan, score 4, neuer Titel) -> created=false, score=4, EINE Zeile
  r2 := career.fn_record_job_match(jsonb_build_object(
    'source','bundesagentur','external_id','10000-ABC-S','title','Scrum Master (m/w/d)','score',4));
  IF (r2->>'created')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [2] created should be false: %', r2; END IF;
  IF (r2->>'score')::int IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'FAIL [2] score not updated: %', r2; END IF;
  SELECT count(*) INTO v_cnt FROM career.job_matches WHERE external_id='10000-ABC-S';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [2] expected 1 row on conflict, got %', v_cnt; END IF;
  SELECT title INTO v_title FROM career.job_matches WHERE external_id='10000-ABC-S';
  IF v_title <> 'Scrum Master (m/w/d)' THEN RAISE EXCEPTION 'FAIL [2] title not updated: %', v_title; END IF;
  RAISE NOTICE 'PASS [2] UPSERT on (source, external_id) (idempotent, score+title updated)';

  -- TEST 3: forwarded OHNE external_id -> created=true, kein score; zwei Inserts = zwei Zeilen (kein Dedup-Key)
  r := career.fn_record_job_match(jsonb_build_object('source','forwarded','title','Agile Coach'));
  IF (r->>'created')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [3a]: %', r; END IF;
  IF r ? 'score' THEN RAISE EXCEPTION 'FAIL [3a] forwarded score should be absent (stripped): %', r; END IF;
  PERFORM career.fn_record_job_match(jsonb_build_object('source','forwarded','title','Agile Coach'));
  SELECT count(*) INTO v_cnt FROM career.job_matches WHERE source='forwarded' AND external_id IS NULL;
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [3b] expected 2 forwarded rows (no dedup), got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [3] forwarded INSERT (no external_id -> no dedup)';

  -- TEST 4: korrigierbare Ablehnung -> {ok:false}, KEIN Write, kein RAISE
  r := career.fn_record_job_match(jsonb_build_object('source','forwarded','title','   '));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4 empty title]: %', r; END IF;
  -- 'linkedin' ist ein BOARD, keine Ingestion-QUELLE -> weiter abgelehnt (source-Whitelist unveraendert streng)
  r := career.fn_record_job_match(jsonb_build_object('source','linkedin','title','X'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4 bad source linkedin]: %', r; END IF;
  r := career.fn_record_job_match(jsonb_build_object('source','bundesagentur','external_id','Z','title','X','score',7));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4 score range]: %', r; END IF;
  SELECT count(*) INTO v_cnt FROM career.job_matches WHERE external_id='Z';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [4] rejected score wrote a row'; END IF;
  -- Nicht-Zahl-Score-STRING -> graceful IGNORIERT (kein RAISE, recorded ohne score), Reviewer A1/A8
  r := career.fn_record_job_match(jsonb_build_object('source','bundesagentur','external_id','SBAD','title','Bad Score Job','score','bad'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4 string score should be ignored, not RAISE]: %', r; END IF;
  IF r ? 'score' THEN RAISE EXCEPTION 'FAIL [4 string score should be dropped (NULL)]: %', r; END IF;
  RAISE NOTICE 'PASS [4] korrigierbare Ablehnung (title/source/score-range -> ok:false) + Nicht-Zahl-Score graceful ignoriert';

  -- TEST 4b: die NEUEN Aggregator-Quellen adzuna + jsearch werden AKZEPTIERT (Whitelist erweitert)
  r := career.fn_record_job_match(jsonb_build_object('source','adzuna','external_id','ADZ-1','title','Product Owner'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4b adzuna accepted]: %', r; END IF;
  r := career.fn_record_job_match(jsonb_build_object('source','jsearch','external_id','JS-1','title','Data Engineer','board','LinkedIn'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4b jsearch accepted]: %', r; END IF;
  SELECT board INTO v_board FROM career.job_matches WHERE external_id='JS-1' AND source='jsearch';
  IF v_board IS DISTINCT FROM 'LinkedIn' THEN RAISE EXCEPTION 'FAIL [4b jsearch board=% (erwartet LinkedIn)]', v_board; END IF;
  RAISE NOTICE 'PASS [4b] adzuna/jsearch akzeptiert + board=job_publisher gespeichert';

  -- TEST 6: Cross-Source-NICHT-Kollision: gleiche external_id, VERSCHIEDENE source, gleiche Person -> ZWEI Zeilen,
  --         BEIDE created=true (beweist: Dedup-Key ist source-skopiert; v_existing/created-Flag source-aware).
  r  := career.fn_record_job_match(jsonb_build_object('source','bundesagentur','external_id','DUP1','title','Same Job BA'));
  r2 := career.fn_record_job_match(jsonb_build_object('source','jsearch','external_id','DUP1','title','Same Job JS','board','LinkedIn'));
  IF (r->>'created')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6 BA created]: %', r; END IF;
  IF (r2->>'created')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6 JS created should be TRUE (source-scoped)]: %', r2; END IF;
  SELECT count(*) INTO v_cnt FROM career.job_matches WHERE external_id='DUP1';
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [6] expected 2 rows (source-scoped), got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [6] Cross-Source keine Kollision (gleiche external_id, andere source -> 2 Zeilen, beide created)';

  -- TEST 7: gleiche (source, external_id, person) -> genau EIN UPSERT (Verhalten erhalten, jetzt jsearch)
  PERFORM career.fn_record_job_match(jsonb_build_object('source','jsearch','external_id','JS-1','title','Data Engineer 2','board','LinkedIn'));
  SELECT count(*) INTO v_cnt FROM career.job_matches WHERE external_id='JS-1' AND source='jsearch';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [7] expected 1 jsearch row on re-record, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [7] gleiche (source, external_id, person) -> 1 UPSERT';

  -- TEST 8: board COALESCE-Merge: Re-Record ohne board bewahrt den bestehenden board-Wert (nicht ueberschreiben mit NULL)
  PERFORM career.fn_record_job_match(jsonb_build_object('source','jsearch','external_id','JS-1','title','Data Engineer 3'));
  SELECT board INTO v_board FROM career.job_matches WHERE external_id='JS-1' AND source='jsearch';
  IF v_board IS DISTINCT FROM 'LinkedIn' THEN RAISE EXCEPTION 'FAIL [8] board merged away to % (erwartet LinkedIn bewahrt)', v_board; END IF;
  RAISE NOTICE 'PASS [8] board COALESCE-Merge (Re-Record ohne board bewahrt LinkedIn)';

  -- TEST 5 (P2a Person-Praezedenz: explicit person_id > chat_id-resolved > Owner-Fallback)
  -- (5a) Owner-Fallback (kein person_id/chat_id) -> erika
  r := career.fn_record_job_match(jsonb_build_object('source','forwarded','title','P5 Owner'));
  SELECT person_id INTO v_pid FROM career.job_matches WHERE id = (r->>'job_match_id')::bigint;
  IF v_pid IS DISTINCT FROM 'erika' THEN RAISE EXCEPTION 'FAIL [5a] Owner-Fallback person_id=% (erwartet erika)', v_pid; END IF;
  -- (5b) chat_id-resolved (Tool-Pfad): chat_id=222 -> lena
  r := career.fn_record_job_match(jsonb_build_object('source','forwarded','title','P5 chat','chat_id',222));
  SELECT person_id INTO v_pid FROM career.job_matches WHERE id = (r->>'job_match_id')::bigint;
  IF v_pid IS DISTINCT FROM 'lena' THEN RAISE EXCEPTION 'FAIL [5b] chat_id-resolved person_id=% (erwartet lena)', v_pid; END IF;
  -- (5c) explicit person_id (trusted cron) gewinnt vor chat_id
  r := career.fn_record_job_match(jsonb_build_object('source','forwarded','title','P5 explicit','person_id','lena','chat_id',111));
  SELECT person_id INTO v_pid FROM career.job_matches WHERE id = (r->>'job_match_id')::bigint;
  IF v_pid IS DISTINCT FROM 'lena' THEN RAISE EXCEPTION 'FAIL [5c] explicit person_id=% (erwartet lena, schlaegt chat_id)', v_pid; END IF;
  -- (5d) nicht-numerischer chat_id -> RAISE-frei -> Owner-Fallback (kein RAISE, kein Owner-Alert)
  r := career.fn_record_job_match(jsonb_build_object('source','forwarded','title','P5 badchat','chat_id','abc'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [5d] badchat soll graceful Owner-Fallback (kein RAISE): %', r; END IF;
  SELECT person_id INTO v_pid FROM career.job_matches WHERE id = (r->>'job_match_id')::bigint;
  IF v_pid IS DISTINCT FROM 'erika' THEN RAISE EXCEPTION 'FAIL [5d] badchat person_id=% (erwartet Owner erika)', v_pid; END IF;
  RAISE NOTICE 'PASS [5] Person-Praezedenz (explicit > chat_id > Owner; badchat graceful)';
END $$;
ROLLBACK;
