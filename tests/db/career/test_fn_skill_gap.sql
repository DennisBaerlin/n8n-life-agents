-- tests/db/career/test_fn_skill_gap.sql
-- career.fn_skill_gap: deterministische Soll-Ist-Luecke je Ziel-Rolle (RAISE-frei, pure).
-- missing / weak / overskilled / met / presence-only / Blocker / mehrere Rollen / leeres Profil / Junk.
BEGIN;
DO $$
DECLARE
  v_plan    jsonb;
  v_prof    jsonb;
  v_res     jsonb;
  v_role    jsonb;
BEGIN
  -- ---------- Fixtures ----------
  -- Soll: Data Analyst verlangt Statistik(advanced, Blocker), Python(intermediate), Kommunikation(presence-only),
  --       Kanban(beginner, ueberskillt). Software-Entwickler hat kein required_skills (-> skip).
  v_plan := jsonb_build_object('target_roles', jsonb_build_array(
    jsonb_build_object('title','Data Analyst','required_skills', jsonb_build_array(
      jsonb_build_object('name','Statistik','min_level','advanced','is_blocker', true),
      jsonb_build_object('name','Python','min_level','intermediate'),
      jsonb_build_object('name','Kommunikation'),                         -- presence-only
      jsonb_build_object('name','Kanban','min_level','beginner'))),
    jsonb_build_object('title','Software-Entwickler')));                  -- kein required_skills -> skip

  -- Ist: Statistik beginner (zu schwach -> weak+blocker), Kommunikation expert (presence erfuellt -> met),
  --      Kanban expert (ueber Ziel -> overskilled), Python fehlt (-> missing). Case-Test: 'STATISTIK'.
  v_prof := jsonb_build_object('skills', jsonb_build_array(
    jsonb_build_object('name','STATISTIK','level','beginner'),
    jsonb_build_object('name','Kommunikation','level','expert'),
    jsonb_build_object('name','Kanban','level','expert')));

  v_res := career.fn_skill_gap(v_plan, v_prof);

  -- gap_count = Python(missing) + Statistik(weak) = 2; blocker_gap_count = Statistik(weak+blocker) = 1; overskill = Kanban = 1
  IF (v_res->>'gap_count')::int <> 2 THEN RAISE EXCEPTION 'FAIL [gap_count=2]: %', v_res; END IF;
  IF (v_res->>'blocker_gap_count')::int <> 1 THEN RAISE EXCEPTION 'FAIL [blocker_gap_count=1]: %', v_res; END IF;
  IF (v_res->>'overskill_count')::int <> 1 THEN RAISE EXCEPTION 'FAIL [overskill_count=1]: %', v_res; END IF;

  -- roles[] enthaelt nur Data Analyst (Software-Entwickler ohne required_skills -> geskippt)
  IF jsonb_array_length(v_res->'roles') <> 1 THEN RAISE EXCEPTION 'FAIL [1 role with required_skills]: %', v_res; END IF;
  v_role := v_res->'roles'->0;
  IF v_role->>'title' <> 'Data Analyst' THEN RAISE EXCEPTION 'FAIL [role title]: %', v_role; END IF;
  IF (v_role->>'required_count')::int <> 4 THEN RAISE EXCEPTION 'FAIL [required_count=4]: %', v_role; END IF;
  -- met = Kommunikation(presence) + Kanban(over) = 2
  IF (v_role->>'met_count')::int <> 2 THEN RAISE EXCEPTION 'FAIL [met_count=2]: %', v_role; END IF;

  -- Python in missing
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_role->'missing') m WHERE m->>'name'='Python') THEN
    RAISE EXCEPTION 'FAIL [Python missing]: %', v_role; END IF;
  -- Statistik in weak, have=beginner, required=advanced, blocker=true (case-insensitiver Match STATISTIK<->Statistik)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_role->'weak') w
                 WHERE w->>'name'='Statistik' AND w->>'have'='beginner' AND w->>'required'='advanced'
                   AND (w->>'is_blocker')::boolean) THEN
    RAISE EXCEPTION 'FAIL [Statistik weak+blocker case-insensitive]: %', v_role; END IF;
  -- Kanban in overskilled
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_role->'overskilled') o WHERE o->>'name'='Kanban') THEN
    RAISE EXCEPTION 'FAIL [Kanban overskilled]: %', v_role; END IF;
  RAISE NOTICE 'PASS [1] missing/weak/overskilled/met + presence-only + blocker + case-insensitiv + skip-no-required';

  -- ---------- TEST 2: leeres/fehlendes Profil -> alle required = missing ----------
  v_res := career.fn_skill_gap(v_plan, '{}'::jsonb);
  -- Data Analyst hat 4 required -> 4 missing; Blocker = Statistik = 1
  IF (v_res->>'gap_count')::int <> 4 THEN RAISE EXCEPTION 'FAIL [2 empty profile gap=4]: %', v_res; END IF;
  IF (v_res->>'blocker_gap_count')::int <> 1 THEN RAISE EXCEPTION 'FAIL [2 empty profile blocker=1]: %', v_res; END IF;
  IF career.fn_skill_gap(v_plan, NULL) IS NULL THEN RAISE EXCEPTION 'FAIL [2 NULL profile -> no crash]'; END IF;
  RAISE NOTICE 'PASS [2] leeres/NULL-Profil -> alle missing, kein Crash';

  -- ---------- TEST 3: kein Plan / kein target_roles -> leeres Ergebnis, kein RAISE ----------
  v_res := career.fn_skill_gap('{}'::jsonb, v_prof);
  IF (v_res->>'gap_count')::int <> 0 OR jsonb_array_length(v_res->'roles') <> 0 THEN
    RAISE EXCEPTION 'FAIL [3 no plan -> empty]: %', v_res; END IF;
  IF career.fn_skill_gap(NULL, NULL) IS NULL THEN RAISE EXCEPTION 'FAIL [3 NULL/NULL -> no crash]'; END IF;
  RAISE NOTICE 'PASS [3] kein Plan/target_roles -> leer, kein Crash';

  -- ---------- TEST 4: presence-only erfuellt + Ist ohne level -> weak ----------
  -- Soll: SkillA presence-only, SkillB min_level intermediate. Ist: SkillA (kein level), SkillB (kein level).
  v_res := career.fn_skill_gap(
    jsonb_build_object('target_roles', jsonb_build_array(jsonb_build_object('title','R','required_skills',
      jsonb_build_array(jsonb_build_object('name','SkillA'),
                        jsonb_build_object('name','SkillB','min_level','intermediate'))))),
    jsonb_build_object('skills', jsonb_build_array(
      jsonb_build_object('name','SkillA'),                 -- presence-only -> met
      jsonb_build_object('name','SkillB'))));              -- kein level -> rank 0 < intermediate -> weak
  IF (v_res->>'gap_count')::int <> 1 THEN RAISE EXCEPTION 'FAIL [4 presence-only/no-level gap=1]: %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'roles'->0->'weak') w WHERE w->>'name'='SkillB') THEN
    RAISE EXCEPTION 'FAIL [4 SkillB weak]: %', v_res; END IF;
  RAISE NOTICE 'PASS [4] presence-only erfuellt + Ist-ohne-level -> weak';

  -- ---------- TEST 5: Junk-is_blocker + Junk-level -> kein RAISE ----------
  v_res := career.fn_skill_gap(
    jsonb_build_object('target_roles', jsonb_build_array(jsonb_build_object('title','R','required_skills',
      jsonb_build_array(jsonb_build_object('name','X','min_level','guru','is_blocker','maybe'))))),
    jsonb_build_object('skills', jsonb_build_array(jsonb_build_object('name','X','level','wizard'))));
  -- min_level 'guru' -> rank 0; level 'wizard' -> rank 0; 0==0 -> met -> kein gap; is_blocker 'maybe' -> false
  IF (v_res->>'gap_count')::int <> 0 THEN RAISE EXCEPTION 'FAIL [5 junk -> met, gap=0]: %', v_res; END IF;
  RAISE NOTICE 'PASS [5] Junk-level/is_blocker -> kein RAISE';

  -- ---------- TEST 6: gleiche Faehigkeit in mehreren Rollen zaehlt je Faehigkeit einmal ----------
  -- Python ist in A Pflicht und fehlt, in B ohne Pflicht -> 1 Luecke, 1 Blocker (Luecke und Pflicht in einer Rolle).
  v_res := career.fn_skill_gap(
    '{"target_roles":[{"title":"A","required_skills":[{"name":"Python","is_blocker":true}]},
                      {"title":"B","required_skills":[{"name":" python "}]}]}', '{}'::jsonb);
  IF (v_res->>'gap_count')::int <> 1 OR (v_res->>'blocker_gap_count')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [6a gleiche Luecke in 2 Rollen: 1 / 1]: %', v_res; END IF;
  IF jsonb_array_length(v_res->'roles'->0->'missing') <> 1 OR jsonb_array_length(v_res->'roles'->1->'missing') <> 1 THEN
    RAISE EXCEPTION 'FAIL [6a roles[] bleibt je Rolle voll]: %', v_res; END IF;

  -- Pflicht in B, dort erfuellt; in A nur Luecke ohne Pflicht -> kein Blocker (Pflicht ohne Luecke zaehlt nicht).
  v_res := career.fn_skill_gap(
    '{"target_roles":[{"title":"A","required_skills":[{"name":"SQL","min_level":"advanced"}]},
                      {"title":"B","required_skills":[{"name":"SQL","min_level":"beginner","is_blocker":true}]}]}',
    '{"skills":[{"name":"SQL","level":"intermediate"}]}');
  IF (v_res->>'gap_count')::int <> 1 OR (v_res->>'blocker_gap_count')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [6b Pflicht ohne Luecke: 1 Luecke / 0 Blocker]: %', v_res; END IF;

  -- schwach in beiden Rollen mit verschiedenem Mindest-Level -> eine Luecke.
  v_res := career.fn_skill_gap(
    '{"target_roles":[{"title":"A","required_skills":[{"name":"Excel","min_level":"advanced"}]},
                      {"title":"B","required_skills":[{"name":"excel","min_level":"expert"}]}]}',
    '{"skills":[{"name":"Excel","level":"beginner"}]}');
  IF (v_res->>'gap_count')::int <> 1 THEN RAISE EXCEPTION 'FAIL [6c weak in 2 Rollen: 1]: %', v_res; END IF;

  -- uebererfuellt in zwei Rollen -> ein Ueberskill; uebererfuellt in A + schwach in B -> Luecke 1 und Ueberskill 1.
  v_res := career.fn_skill_gap(
    '{"target_roles":[{"title":"A","required_skills":[{"name":"Git","min_level":"beginner"}]},
                      {"title":"B","required_skills":[{"name":"git","min_level":"intermediate"}]}]}',
    '{"skills":[{"name":"Git","level":"expert"}]}');
  IF (v_res->>'overskill_count')::int <> 1 OR (v_res->>'gap_count')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [6d Ueberskill in 2 Rollen: 1 / Luecke 0]: %', v_res; END IF;
  v_res := career.fn_skill_gap(
    '{"target_roles":[{"title":"A","required_skills":[{"name":"Git","min_level":"beginner"}]},
                      {"title":"B","required_skills":[{"name":"git","min_level":"expert"}]}]}',
    '{"skills":[{"name":"Git","level":"advanced"}]}');
  IF (v_res->>'overskill_count')::int <> 1 OR (v_res->>'gap_count')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [6e ueber in A + schwach in B: Ueberskill 1 / Luecke 1]: %', v_res; END IF;
  RAISE NOTICE 'PASS [6] Zaehlung je Faehigkeit (Luecke, Blocker, Ueberskill)';

  RAISE NOTICE 'PASS test_fn_skill_gap';
END $$;
ROLLBACK;
