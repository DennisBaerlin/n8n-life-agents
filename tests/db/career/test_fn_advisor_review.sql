-- tests/db/career/test_fn_advisor_review.sql
-- career.fn_advisor_review: Engine-Vertrag fn(text,jsonb)->{alerts,digest}; WS-1 minimal (Plan-Staleness
-- + Digest). KRITISCH: darf NIE RAISEn (der Drift-Cron wertet alle Advisor in EINER CTE aus).
BEGIN;
DO $$
DECLARE v_res JSONB; v_digest TEXT;
BEGIN
  -- ---------- TEST 1 (no-RAISE bei fehlendem Plan/Profil): {alerts:[], digest.text} ----------
  v_res := career.fn_advisor_review('career');   -- person NULL -> Owner-Fallback (byte-gleiches P0c-Verhalten)
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1] ok: %', v_res; END IF;
  IF jsonb_typeof(v_res->'alerts') <> 'array' OR jsonb_array_length(v_res->'alerts') <> 0 THEN
    RAISE EXCEPTION 'FAIL [1] erwartet leere alerts ohne Plan, got %', v_res->'alerts';
  END IF;
  v_digest := (v_res->'digest'->'lines')::text;
  IF v_digest IS NULL OR v_digest NOT LIKE '%career.advisor.digest_no_plan%' THEN
    RAISE EXCEPTION 'FAIL [1] digest.text ohne Plan: %', v_digest;
  END IF;
  RAISE NOTICE 'PASS [1] no-RAISE ohne Plan/Profil [alerts leer, digest.text gesetzt]';

  -- ---------- Fixtures: Profil + STALE Plan ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_profile','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object('current_title','IT-Projektmanager')))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- last_confirmed_at 400 Tage alt -> > Default-Schwelle 365 -> Staleness-Alert
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_planning','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object(
      'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master')),
      'timeline_years', 2,
      '_meta', jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE - 400, 'YYYY-MM-DD')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ---------- TEST 2 (Staleness-Alert + Digest aus Plan/Profil) ----------
  v_res := career.fn_advisor_review('career');   -- person NULL -> Owner-Fallback (byte-gleiches P0c-Verhalten)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a
                 WHERE a->>'metric_key' = 'plan_staleness') THEN
    RAISE EXCEPTION 'FAIL [2] erwartet plan_staleness alert, got %', v_res->'alerts';
  END IF;
  -- jeder alert traegt ein text-Feld (Generik-Vertrag)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a WHERE COALESCE((a->'msg')::text,'') = '') THEN
    RAISE EXCEPTION 'FAIL [2] alert ohne text-Feld'; END IF;
  v_digest := (v_res->'digest'->'lines')::text;
  IF v_digest NOT LIKE '%IT-Projektmanager%' OR v_digest NOT LIKE '%Scrum Master%' THEN
    RAISE EXCEPTION 'FAIL [2] digest soll Rolle+Zielrolle nennen: %', v_digest;
  END IF;
  RAISE NOTICE 'PASS [2] Staleness-Alert (>365d) + Digest aus Plan/Profil';

  -- ---------- TEST 3 (frischer Plan -> kein Staleness-Alert) ----------
  UPDATE agent.core_contexts
  SET metadata = jsonb_set(metadata, '{facts,_meta,last_confirmed_at}',
      to_jsonb(to_char(CURRENT_DATE - 10, 'YYYY-MM-DD')))
  WHERE name = 'career_planning';
  v_res := career.fn_advisor_review('career');   -- person NULL -> Owner-Fallback (byte-gleiches P0c-Verhalten)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a
             WHERE a->>'metric_key' = 'plan_staleness') THEN
    RAISE EXCEPTION 'FAIL [3] frischer Plan darf keinen Staleness-Alert erzeugen, got %', v_res->'alerts';
  END IF;
  RAISE NOTICE 'PASS [3] frischer Plan (10d) -> kein Staleness-Alert';

  -- ---------- TEST 4 (WS-3 Skill-Gap-Alert: required_skills ohne Match -> skill_gaps) ----------
  -- Primaere Rolle Scrum Master bekommt required_skills; das Profil hat current_title aber KEINE skills
  -- -> Scrum + Python beide missing -> gap_count 2, blocker 1 (Scrum). Plan bleibt frisch (kein Staleness).
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_roles}', jsonb_build_array(
      jsonb_build_object('title','Scrum Master','required_skills', jsonb_build_array(
        jsonb_build_object('name','Scrum','min_level','advanced','is_blocker',true),
        jsonb_build_object('name','Python','min_level','intermediate')))))
    WHERE name = 'career_planning';
  v_res := career.fn_advisor_review('career');   -- person NULL -> Owner-Fallback (byte-gleiches P0c-Verhalten)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a
                 WHERE a->>'metric_key' = 'skill_gaps' AND (a->>'value')::int = 2) THEN
    RAISE EXCEPTION 'FAIL [4] erwartet skill_gaps alert value=2, got %', v_res->'alerts';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a
                 WHERE a->>'metric_key' = 'skill_gaps' AND (a->'msg')::text LIKE '%career.advisor.skill_gaps_blockers%') THEN
    RAISE EXCEPTION 'FAIL [4] Skill-Gap-Alert-Text soll Pflicht/Blocker nennen';
  END IF;
  v_digest := (v_res->'digest'->'lines')::text;
  IF v_digest NOT LIKE '%career.advisor.digest_gaps%"value": 2%' THEN
    RAISE EXCEPTION 'FAIL [4] digest soll Skill-Lücken-Aufschlüsselung tragen: %', v_digest;
  END IF;
  RAISE NOTICE 'PASS [4] skill_gaps Alert (value=2 + Pflicht) + Digest-Aufschlüsselung';

  -- ---------- TEST 5 (alle Skills erfuellt -> kein Skill-Gap-Alert) ----------
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,skills}', jsonb_build_array(
      jsonb_build_object('name','Scrum','level','expert'),
      jsonb_build_object('name','Python','level','expert')))
    WHERE name = 'career_profile';
  v_res := career.fn_advisor_review('career');   -- person NULL -> Owner-Fallback (byte-gleiches P0c-Verhalten)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a WHERE a->>'metric_key' = 'skill_gaps') THEN
    RAISE EXCEPTION 'FAIL [5] erfuellte Skills dürfen keinen Skill-Gap-Alert erzeugen, got %', v_res->'alerts';
  END IF;
  RAISE NOTICE 'PASS [5] alle Skills erfuellt -> kein skill_gaps Alert';

  -- ---------- TEST 6 (A1: primaere Rolle OHNE required_skills, Gap nur in sekundaerer Rolle) ----------
  -- target_roles[0]='Generalist' (keine required_skills) -> nicht in fn_skill_gap.roles[]; die Luecke steckt in
  -- der sekundaeren Rolle. Der Alert darf dann NICHT "weitere Ziele" doppelzaehlen (Hauptsatz nennt die Gesamtzahl).
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_roles}', jsonb_build_array(
      jsonb_build_object('title','Generalist'),
      jsonb_build_object('title','Scrum Master','required_skills', jsonb_build_array(
        jsonb_build_object('name','Scrum','min_level','advanced')))))
    WHERE name = 'career_planning';
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,skills}', '[]'::jsonb)
    WHERE name = 'career_profile';
  v_res := career.fn_advisor_review('career');   -- person NULL -> Owner-Fallback (byte-gleiches P0c-Verhalten)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a
                 WHERE a->>'metric_key' = 'skill_gaps' AND (a->>'value')::int = 1) THEN
    RAISE EXCEPTION 'FAIL [6] erwartet skill_gaps value=1, got %', v_res->'alerts';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a
             WHERE a->>'metric_key' = 'skill_gaps' AND (a->'msg')::text LIKE '%career.advisor.skill_gaps_other%') THEN
    RAISE EXCEPTION 'FAIL [6] A1: leere primäre Rolle darf nicht "weitere Ziele" doppelzählen: %',
      (SELECT (a->'msg')::text FROM jsonb_array_elements(v_res->'alerts') a WHERE a->>'metric_key' = 'skill_gaps');
  END IF;
  RAISE NOTICE 'PASS [6] A1: primäre Rolle ohne required_skills -> kein "weitere Ziele"-Doppelzählen';

  -- ---------- TEST 7 (P0c per-Person): career_planning + career_profile per_user am OWNER-Suffix ----------
  -- P0c entfernt den P0b-Suspend-Guard: die Review liest jetzt den OWNER-Plan am Suffix (agent.fn_owner_person_id),
  -- der geteilte Wrapper hat keine Person-Dimension (P2 = Faecherung). Beweis: family(owner=erika) +
  -- career_planning__erika/career_profile__erika mit echter Luecke -> der Skill-Gap WIRKT (Alert + Digest-Zeile),
  -- NICHT suspendiert. Die scope-Registry steht auf per_user (P0c-Zustand) — die fn liest dennoch ueber den Suffix.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fam',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES
    ('career_profile','per_user','own_user_only','career'),
    ('career_planning','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user';
  -- Owner-Suffix-Contexts: Plan mit required_skills (Scrum Master), Profil OHNE die Skills -> echte Luecke.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_planning__erika','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object(
      'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master','required_skills',
        jsonb_build_array(jsonb_build_object('name','Scrum','min_level','advanced','is_blocker',true)))),
      'timeline_years', 2,
      '_meta', jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE - 10, 'YYYY-MM-DD'))))),
   ('career_profile__erika','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object('current_title','IT-Projektmanager','skills','[]'::jsonb)))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  v_res := career.fn_advisor_review('career');   -- person NULL -> Owner-Fallback (byte-gleiches P0c-Verhalten)
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [7] kein RAISE-Schutz: %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a WHERE a->>'metric_key' = 'skill_gaps') THEN
    RAISE EXCEPTION 'FAIL [7] kein skill_gaps-Alert trotz Owner-Suffix-Lücke (per-Person-Read greift nicht): %', v_res->'alerts';
  END IF;
  IF ((v_res->'digest'->'lines')::text) NOT LIKE '%career.advisor.digest_gaps%' THEN
    RAISE EXCEPTION 'FAIL [7] Digest-Skill-Zeile fehlt trotz Owner-Suffix-Lücke: %', (v_res->'digest'->'lines')::text;
  END IF;
  RAISE NOTICE 'PASS [7] P0c per-Person [Owner-Suffix-Read -> skill_gaps wirkt, Suspend-Guard weg]';

  -- ---------- TEST 8 (P2a explicit person path): p_person_id liest die EIGENEN Fakten der Person ----------
  -- erika hat (Test 7) eine echte Skill-Luecke. lena bekommt einen EIGENEN Plan OHNE Luecke (Profil deckt Soll).
  -- fn_advisor_review('career','erika') -> Luecke; ('career','lena') -> KEINE Luecke -> beweist Person-Threading
  -- (der geteilte Wrapper reicht p_person_id jetzt uniform durch; P0c las pauschal den Owner).
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                         'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
      jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                         'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))
    WHERE name = 'family';
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_planning__lena','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object(
      'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master','required_skills',
        jsonb_build_array(jsonb_build_object('name','Scrum','min_level','advanced')))),
      'timeline_years', 2,
      '_meta', jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE - 10, 'YYYY-MM-DD'))))),
   ('career_profile__lena','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object('current_title','Agile Coach',
      'skills', jsonb_build_array(jsonb_build_object('name','Scrum','level','expert')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  v_res := career.fn_advisor_review('career', 'erika');   -- explizit erika -> Luecke wirkt
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a WHERE a->>'metric_key' = 'skill_gaps') THEN
    RAISE EXCEPTION 'FAIL [8a] erika-Pfad: erwartet Skill-Gap, got %', v_res->'alerts'; END IF;
  v_res := career.fn_advisor_review('career', 'lena');    -- explizit lena -> KEINE Luecke (eigenes Profil deckt Soll)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'alerts') a WHERE a->>'metric_key' = 'skill_gaps') THEN
    RAISE EXCEPTION 'FAIL [8b] lena-Pfad las nicht lenas Fakten (fälschlich Skill-Gap): %', v_res->'alerts'; END IF;
  IF ((v_res->'digest'->'lines')::text) NOT LIKE '%Agile Coach%' THEN
    RAISE EXCEPTION 'FAIL [8c] lena-Digest soll lenas current_title (Agile Coach) nennen: %', (v_res->'digest'->'lines')::text; END IF;
  RAISE NOTICE 'PASS [8] explicit person path (erika->Lücke, lena->keine Lücke; Digest aus lenas Fakten)';
END $$;
ROLLBACK;
