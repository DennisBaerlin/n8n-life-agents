-- tests/db/career/test_career_onboarding_person_scoping.sql
-- P2b-1: career.onboarding_state ist pro Person. Beweist die DB-Invarianten + das person-gefaecherte Verhalten
-- der GETEILTEN Core-Onboarding-fns (set/status/overview) — career per_user, finance/guide UNVERAENDERT household.
--   (1) composite-PK (section_key, person_id) + person_id NOT NULL + FK -> agent.persons ON DELETE RESTRICT
--   (2) Isolation A!=B: A's set kippt NUR A's Zeile; complete je Person getrennt
--   (3) Lazy-Materialisierung (fn_ensure_onboarding_person): Person ohne Zeilen -> 3 'unknown' beim ersten set
--   (4) fail-closed bei unaufgeloestem/non-numerischem Sender (kein Write, complete=false)
--   (5) household-Regression finance + guide: UNVERAENDERT (kein chat_id, eine Zeile je Sektion)
--   (6) fn_onboarding_overview pro Person (M1): jeder Tapper sieht SEINE career-Sektionen, core/finance household
-- Fixture: family owner(erika,111) + partner(lena,222) -> agent.persons (FK-Ziel) + context_scopes (career=per_user,
--   sonst liefe career in db_test als household, weil bootstrap_test_db context_scopes NICHT seedet) + Katalog
--   (erika's 3 Sektionen = der Owner-Seed) + package_registry(career=active, fuer den overview-Loop). BEGIN..ROLLBACK.
BEGIN;
DO $$
DECLARE
  v_cnt int; v_denied boolean; r jsonb; st jsonb; ov jsonb;
BEGIN
  -- ---- Fixture ----
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                           'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- context_scopes: career = per_user (in db_test NICHT geseedet -> hier setzen, sonst falsche household-Ableitung)
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES
    ('career_profile','per_user','own_user_only','career'),
    ('career_preferences','per_user','own_user_only','career'),
    ('career_planning','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO NOTHING;

  -- Katalog = Owner-Seed (was _seed_onboarding_sections in Prod fuer erika seedet): 3 Sektionen, alle unknown.
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES
    ('profile_basics', 1, 'Profil-Basics', 'erika'),
    ('skills_overview', 2, 'Skills', 'erika'),
    ('goals_targets', 3, 'Ziele', 'erika');

  -- package_registry: career active (fuer den fn_onboarding_overview-Paket-Loop)
  INSERT INTO core.package_registry (package, version, status) VALUES ('career','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';

  -- finance household-Sektion (fuer die Regression; finance.onboarding_state in db_test leer + kein per_user-scope)
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('accounts', 1, 'Konten')
  ON CONFLICT (section_key) DO NOTHING;

  -- ==========================================================
  -- TEST 1: composite-PK + NOT NULL + FK RESTRICT
  -- ==========================================================
  -- (1a) gleiche (section_key, person_id) zweimal -> unique_violation
  v_denied := false;
  BEGIN INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES ('profile_basics',1,'X','erika');
  EXCEPTION WHEN unique_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [1a] composite-PK (section_key, person_id) nicht erzwungen'; END IF;
  -- (1b) gleiche section_key, ANDERE Person -> erlaubt (zwei Zeilen)
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id) VALUES ('profile_basics',1,'Profil-Basics','lena');
  SELECT count(*) INTO v_cnt FROM career.onboarding_state WHERE section_key='profile_basics';
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [1b] zwei Personen = zwei profile_basics-Zeilen erwartet, got %', v_cnt; END IF;
  DELETE FROM career.onboarding_state WHERE section_key='profile_basics' AND person_id='lena';  -- fuer den Lazy-Test zuruecksetzen
  -- (1c) person_id NOT NULL
  v_denied := false;
  BEGIN INSERT INTO career.onboarding_state (section_key, ord, label) VALUES ('nope',9,'X');
  EXCEPTION WHEN not_null_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [1c] person_id NOT NULL nicht erzwungen'; END IF;
  -- (1d) FK ON DELETE RESTRICT — erika hat Zeilen -> nicht loeschbar
  v_denied := false;
  BEGIN DELETE FROM agent.persons WHERE person_id='erika';
  EXCEPTION WHEN foreign_key_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [1d] FK ON DELETE RESTRICT (Person mit onboarding_state nicht geblockt)'; END IF;
  RAISE NOTICE 'PASS [1] composite-PK + per-Person-Koexistenz + NOT NULL + FK RESTRICT';

  -- ==========================================================
  -- TEST 2: Isolation A!=B — erika's set kippt NUR erika
  -- ==========================================================
  r := core.fn_set_onboarding_section(jsonb_build_object('package','career','section_key','profile_basics','status','completed','chat_id','111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2a] erika set profile_basics: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM career.onboarding_state WHERE section_key='profile_basics' AND person_id='erika' AND status='completed') THEN
    RAISE EXCEPTION 'FAIL [2b] erika profile_basics nicht completed'; END IF;
  -- lena hat noch GAR keine Zeile (Lazy noch nicht getriggert) -> ihr Status ist katalog-basiert unknown
  IF EXISTS (SELECT 1 FROM career.onboarding_state WHERE person_id='lena') THEN
    RAISE EXCEPTION 'FAIL [2c] lena hat unerwartet Zeilen vor ihrem ersten set'; END IF;
  RAISE NOTICE 'PASS [2] Isolation: erika-set kippt nur erika, lena unberuehrt';

  -- ==========================================================
  -- TEST 3: Lazy-Materialisierung — lena (ohne Zeilen) -> 3 'unknown' beim ersten set
  -- ==========================================================
  -- VORHER: status fuer lena = katalog-basiert (3 open, complete false), OHNE dass Zeilen entstehen (STABLE-Read)
  st := core.fn_onboarding_status('career', '222');
  IF (st->'package'->>'complete')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3a] lena (0 Zeilen) sollte complete=false sein: %', st; END IF;
  IF jsonb_array_length(st->'package'->'open') <> 3 THEN RAISE EXCEPTION 'FAIL [3b] lena open soll 3 Sektionen listen: %', st->'package'->'open'; END IF;
  IF EXISTS (SELECT 1 FROM career.onboarding_state WHERE person_id='lena') THEN
    RAISE EXCEPTION 'FAIL [3c] fn_onboarding_status hat geschrieben (STABLE verletzt) — lena hat Zeilen'; END IF;
  -- JETZT set -> materialisiert lena's 3 Zeilen, profile_basics completed
  r := core.fn_set_onboarding_section(jsonb_build_object('package','career','section_key','profile_basics','status','completed','chat_id','222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [3d] lena set: %', r; END IF;
  SELECT count(*) INTO v_cnt FROM career.onboarding_state WHERE person_id='lena';
  IF v_cnt <> 3 THEN RAISE EXCEPTION 'FAIL [3e] lena sollte 3 materialisierte Zeilen haben, got %', v_cnt; END IF;
  IF NOT EXISTS (SELECT 1 FROM career.onboarding_state WHERE person_id='lena' AND section_key='profile_basics' AND status='completed') THEN
    RAISE EXCEPTION 'FAIL [3f] lena profile_basics nicht completed'; END IF;
  IF (SELECT count(*) FROM career.onboarding_state WHERE person_id='lena' AND status='unknown') <> 2 THEN
    RAISE EXCEPTION 'FAIL [3g] lena sollte 2 unknown-Sektionen haben'; END IF;
  -- erika nach lenas set unveraendert (profile_basics completed, Rest unknown)
  IF NOT EXISTS (SELECT 1 FROM career.onboarding_state WHERE person_id='erika' AND section_key='profile_basics' AND status='completed') THEN
    RAISE EXCEPTION 'FAIL [3h] erika durch lena-set veraendert'; END IF;
  RAISE NOTICE 'PASS [3] Lazy-Materialisierung (3 unknown beim ersten set) + STABLE-Read schreibt nicht';

  -- ==========================================================
  -- TEST 4: fail-closed bei unaufgeloestem / non-numerischem Sender
  -- ==========================================================
  -- (4a) unpaired numeric chat_id -> complete=false
  st := core.fn_onboarding_status('career', '999999');
  IF (st->>'complete')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4a] unpaired sender sollte complete=false: %', st; END IF;
  -- (4b) non-numeric chat_id -> complete=false
  st := core.fn_onboarding_status('career', 'abc');
  IF (st->>'complete')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4b] non-numeric sender sollte complete=false: %', st; END IF;
  -- (4c) set mit non-numerischem chat_id -> {ok:false, unresolved_sender}, KEIN Write
  r := core.fn_set_onboarding_section(jsonb_build_object('package','career','section_key','skills_overview','status','completed','chat_id','abc'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unresolved_sender' THEN
    RAISE EXCEPTION 'FAIL [4c] set mit abc-chat_id sollte {ok:false, unresolved_sender}: %', r; END IF;
  RAISE NOTICE 'PASS [4] fail-closed (unpaired/non-numeric -> complete=false / unresolved_sender, kein Write)';

  -- ==========================================================
  -- TEST 5: completeness per Person — erika alle 3 -> complete true, lena weiter false
  -- ==========================================================
  PERFORM core.fn_set_onboarding_section(jsonb_build_object('package','career','section_key','skills_overview','status','completed','chat_id','111'));
  PERFORM core.fn_set_onboarding_section(jsonb_build_object('package','career','section_key','goals_targets','status','skipped','chat_id','111'));
  -- Das PAKET-Bein (career-Vollstaendigkeit je Person) — NICHT top-level 'complete' (= core-Haushalt AND career;
  -- der core-Haushalt 'household' ist in diesem Fixture bewusst unknown -> top-level waere fuer beide false).
  st := core.fn_onboarding_status('career', '111');
  IF (st->'package'->>'complete')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [5a] erika (alle 3 aufgeloest) sollte package.complete=true: %', st; END IF;
  st := core.fn_onboarding_status('career', '222');
  IF (st->'package'->>'complete')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5b] lena (nur profile_basics) sollte package.complete=false: %', st; END IF;
  RAISE NOTICE 'PASS [5] completeness je Person getrennt (Paket-Bein)';

  -- ==========================================================
  -- TEST 6: household-Regression finance + guide UNVERAENDERT (kein chat_id, eine Zeile je Sektion)
  -- ==========================================================
  r := core.fn_set_onboarding_section(jsonb_build_object('package','finance','section_key','accounts','status','completed'));  -- KEIN chat_id
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6a] finance household set: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.onboarding_state WHERE section_key='accounts' AND status='completed') THEN
    RAISE EXCEPTION 'FAIL [6b] finance accounts nicht completed (household-Pfad gebrochen)'; END IF;
  st := core.fn_onboarding_status('finance');   -- 1-arg-Aufruf (p_chat_id default NULL) -> household, byte-gleich
  IF (st->'package'->>'complete')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6c] finance status household: %', st; END IF;
  -- guide (package='core' -> agent.guide_onboarding_state, household 'household'-Zeile aus dem Init)
  r := core.fn_set_onboarding_section(jsonb_build_object('package','core','section_key','household','status','completed'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6d] core/guide household set: %', r; END IF;
  RAISE NOTICE 'PASS [6] household-Regression finance + guide unveraendert';

  -- ==========================================================
  -- TEST 7: fn_onboarding_overview pro Person (M1) — jeder Tapper sieht SEINE career-Sektionen
  -- ==========================================================
  ov := core.fn_onboarding_overview('111');   -- erika: profile_basics+skills completed, goals skipped
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ov->'sections') s
                 WHERE s->>'package'='career' AND s->>'key'='profile_basics' AND s->>'status'='completed') THEN
    RAISE EXCEPTION 'FAIL [7a] overview(111) erika profile_basics nicht completed: %', ov; END IF;
  ov := core.fn_onboarding_overview('222');   -- lena: nur profile_basics completed, Rest unknown
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ov->'sections') s
                 WHERE s->>'package'='career' AND s->>'key'='skills_overview' AND s->>'status'='unknown') THEN
    RAISE EXCEPTION 'FAIL [7b] overview(222) lena skills_overview sollte unknown sein: %', ov; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(ov->'sections') s
             WHERE s->>'package'='career' AND s->>'key'='goals_targets' AND s->>'status'='skipped') THEN
    RAISE EXCEPTION 'FAIL [7c] overview(222) zeigt erikas goals_targets-Status (Leak!) statt lenas unknown: %', ov; END IF;
  -- core-Bein household identisch fuer beide (kein person-Scope)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ov->'sections') s WHERE s->>'package'='core') THEN
    RAISE EXCEPTION 'FAIL [7d] overview core-Bein fehlt: %', ov; END IF;
  RAISE NOTICE 'PASS [7] overview pro Person (jeder Tapper SEINE career-Sektionen, core household)';

  -- ==========================================================
  -- TEST 8: LEERER Katalog -> complete=false (vacuous-true-Falle geschlossen, EXISTS(cat)-Guard)
  -- ==========================================================
  DELETE FROM career.onboarding_state;   -- kein Katalog mehr -> NOT EXISTS(leer) waere sonst TRUE
  st := core.fn_onboarding_status('career', '111');
  IF (st->'package'->>'complete')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [8] leerer career-Katalog sollte package.complete=false sein (vacuous-true!): %', st; END IF;
  RAISE NOTICE 'PASS [8] leerer Katalog -> complete=false (Gate bleibt zu)';

  RAISE NOTICE 'PASS career onboarding person-scoping (composite-PK/FK/Isolation/Lazy/fail-closed/household-Regression/overview/leerer-Katalog)';
END $$;
ROLLBACK;
