-- tests/db/career/test_fn_render_career_preferences.sql
-- career.fn_render_career_preferences: Header-Render aus metadata.facts (Vorbild test_fn_render_career_profile).
-- Deckt u. a. den jsonb_typeof-'null'-Guard auf remote_preference (Reviewer A7).
BEGIN;
DO $$
DECLARE v_out TEXT;
BEGIN
  -- kein Kontext / leere facts -> NULL (Engine rendert nur Prosa)
  IF career.fn_render_career_preferences('career_preferences') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [no row]: erwartet NULL'; END IF;

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_preferences', 'test', NULL, 'lazy', '', 'agent', 'career',
          jsonb_build_object('facts', jsonb_build_object(
            'preferred_aspects', jsonb_build_array('Remote-Anteil','Agile'),
            'disliked_industries', jsonb_build_array('Rüstung'),
            'salary_floor', 70000,
            'remote_preference', 'hybrid',
            'commute_max_km', 40)))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  v_out := career.fn_render_career_preferences('career_preferences');
  IF v_out IS NULL THEN RAISE EXCEPTION 'FAIL [render]: NULL trotz facts'; END IF;
  IF position('Wichtig: Remote-Anteil' IN v_out) = 0 THEN RAISE EXCEPTION 'FAIL [preferred]: %', v_out; END IF;
  IF position('Branchen meiden: Rüstung' IN v_out) = 0 THEN RAISE EXCEPTION 'FAIL [disliked_ind]: %', v_out; END IF;
  IF position('Gehaltsuntergrenze: 70000 EUR' IN v_out) = 0 THEN RAISE EXCEPTION 'FAIL [salary]: %', v_out; END IF;
  IF position('Arbeitsort-Präferenz: hybrid' IN v_out) = 0 THEN RAISE EXCEPTION 'FAIL [remote]: %', v_out; END IF;
  IF position('Max. Pendelweg: 40 km' IN v_out) = 0 THEN RAISE EXCEPTION 'FAIL [commute]: %', v_out; END IF;
  RAISE NOTICE 'PASS [render facts -> Header-Zeilen]';

  -- A7-Guard: remote_preference als JSON-null -> KEINE leere "Arbeitsort-Praeferenz: "-Zeile
  UPDATE agent.core_contexts
     SET metadata = jsonb_build_object('facts', jsonb_build_object('preferred_aspects', jsonb_build_array('X'), 'remote_preference', NULL))
   WHERE name = 'career_preferences';
  v_out := career.fn_render_career_preferences('career_preferences');
  IF position('Arbeitsort-Präferenz:' IN v_out) > 0 THEN
    RAISE EXCEPTION 'FAIL [A7 null-guard]: remote_preference=null rendert leere Zeile: %', v_out; END IF;
  RAISE NOTICE 'PASS [A7: remote_preference=null -> keine Zeile]';
END $$;
ROLLBACK;
