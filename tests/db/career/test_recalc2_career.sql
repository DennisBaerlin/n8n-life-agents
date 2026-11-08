-- tests/db/career/test_recalc2_career.sql
-- Zweitrechnung Runde 2, Career: Skill-Luecken je Rolle, Markt-Trend, Jahresgehalt. Erwartungen von Hand hergeleitet.
-- Werte erfunden. Runway steht mit eigener Haushalts-Fixture in tests/db/cross/test_recalc2_household_cashflow.sql.
-- Fachregeln:
--   * Kompetenz-Skala ordinal beginner < intermediate < advanced < expert; Ist ohne Level gilt als unter jedem
--     geforderten Level; ohne Mindest-Level genuegt das Vorhandensein (Namensvergleich ohne Gross-/Kleinschreibung).
--   * Trend = (juengste - vorherige Messung) / vorherige x 100, eine Nachkommastelle; Messungen ohne Zahl zaehlen nicht.
--   * Jahresgehalt bei Monatsangabe = 12 Gehaelter (Annahme laut fn-Kopf, so im Anzeigetext benannt).
--   Profil: SQL advanced, Python beginner, Docker (ohne Level), Kubernetes expert.
--   (1) Rolle A: PYTHON >= intermediate Pflicht -> schwach (Pflicht); SQL >= advanced -> erfuellt; Spark -> fehlt;
--       Docker >= beginner -> schwach (ohne Level); Kubernetes >= advanced -> uebererfuellt (zaehlt als erfuellt)
--       -> gefordert 5, erfuellt 2, fehlend 1, schwach 2, ueber 1.
--   (2) Rolle B: Python >= intermediate -> schwach; dbt Pflicht -> fehlt; SQL ohne Level -> erfuellt
--       -> gefordert 3, erfuellt 1. Gesamt je FAEHIGKEIT: Luecken Spark, Python, Docker, dbt = 4 (Python steht in
--       beiden Rollen schwach, zaehlt einmal), davon Pflicht Python + dbt = 2, ueber 1.
--   (2c) Je Faehigkeit statt je Rolle (Owner-Entscheid): Rolle A Python + Spark, Rolle B python + dbt, leeres Profil
--       -> Python, Spark, dbt = 3 (nicht 2 + 2).
--   (3) Trend: 90 (vor 60 T.), 100 (vor 30 T.), Messung ohne Zahl (vor 10 T.), 67 (heute) -> 67 vs 100 = -33,0 % down.
--       Vorherige 0 -> kein Trend (flat, trend_pct null).
--   (4) Gehalt 4.250/Monat -> 51.000/Jahr; 61.000/Jahr -> 61.000; ohne Einheit -> unbekannt (NULL).
BEGIN;

DO $$
DECLARE
  g jsonb; ra jsonb; rb jsonb; t jsonb; v_key text;
  v_profile jsonb := '{"skills":[{"name":"SQL","level":"advanced"},{"name":"Python","level":"beginner"},
                                 {"name":"  docker "},{"name":"Kubernetes","level":"expert"}]}';
  v_plan jsonb := '{"target_roles":[
      {"title":"Data Engineer","required_skills":[
         {"name":"PYTHON","min_level":"intermediate","is_blocker":true},{"name":"SQL","min_level":"advanced"},
         {"name":"Spark"},{"name":"Docker","min_level":"beginner"},{"name":"Kubernetes","min_level":"advanced"}]},
      {"title":"Analytics Engineer","required_skills":[
         {"name":"Python","min_level":"intermediate"},{"name":"dbt","is_blocker":true},{"name":"sql"}]}],
    "target_locations":["Musterstadt"]}';
BEGIN
  g := career.fn_skill_gap(v_plan, v_profile);
  SELECT r INTO ra FROM jsonb_array_elements(g->'roles') r WHERE r->>'title' = 'Data Engineer';
  SELECT r INTO rb FROM jsonb_array_elements(g->'roles') r WHERE r->>'title' = 'Analytics Engineer';
  IF (ra->>'required_count')::int <> 5 OR (ra->>'met_count')::int <> 2 OR jsonb_array_length(ra->'missing') <> 1
     OR jsonb_array_length(ra->'weak') <> 2 OR jsonb_array_length(ra->'overskilled') <> 1 THEN
    RAISE EXCEPTION 'FAIL [1] Rolle A: %', ra; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ra->'weak') w WHERE w->>'name' = 'PYTHON' AND (w->>'is_blocker')::boolean)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ra->'weak') w WHERE w->>'name' = 'Docker') THEN
    RAISE EXCEPTION 'FAIL [1b] Rolle A schwach: %', ra->'weak'; END IF;
  IF (rb->>'required_count')::int <> 3 OR (rb->>'met_count')::int <> 1 OR jsonb_array_length(rb->'missing') <> 1
     OR jsonb_array_length(rb->'weak') <> 1 THEN
    RAISE EXCEPTION 'FAIL [2] Rolle B: %', rb; END IF;
  IF (g->>'gap_count')::int <> 4 OR (g->>'blocker_gap_count')::int <> 2 OR (g->>'overskill_count')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [2b] Summen je Faehigkeit: erwartet 4 / 2 / 1, got %', g; END IF;
  RAISE NOTICE 'PASS [1-2] Skill-Luecken je Rolle: Level-Rang, ohne Level, Gross-/Kleinschreibung, Pflicht';

  g := career.fn_skill_gap(
    '{"target_roles":[{"title":"A","required_skills":[{"name":"Python"},{"name":"Spark"}]},
                      {"title":"B","required_skills":[{"name":"python"},{"name":"dbt"}]}]}',
    '{"skills":[]}');
  IF (g->>'gap_count')::int <> 3 THEN
    RAISE EXCEPTION 'FAIL [2c] Skill-Luecken je Faehigkeit: erwartet 3 (Python, Spark, dbt), got %', g; END IF;
  RAISE NOTICE 'PASS [2c] gleiche Faehigkeit in zwei Ziel-Rollen zaehlt einmal';

  v_key := career.fn_market_scope_key('postings', 'Data Engineer', 'Musterstadt');
  DELETE FROM career.market_signals WHERE scope_key = v_key;
  INSERT INTO career.market_signals (scope_key, as_of, postings_count) VALUES
    (v_key, current_date - 60, 90), (v_key, current_date - 30, 100), (v_key, current_date - 10, NULL), (v_key, current_date, 67);
  t := career.fn_market_trend(v_plan);
  IF (t->>'count')::int <> 67 OR (t->>'prev_count')::int <> 100 OR (t->>'trend_pct')::numeric IS DISTINCT FROM -33.0
     OR t->>'direction' <> 'down' THEN
    RAISE EXCEPTION 'FAIL [3a] Trend: erwartet 67 / 100 / -33.0 / down, got %', t; END IF;
  UPDATE career.market_signals SET postings_count = 0 WHERE scope_key = v_key AND as_of = current_date - 30;
  t := career.fn_market_trend(v_plan);
  IF t->>'trend_pct' IS NOT NULL OR t->>'direction' <> 'flat' THEN
    RAISE EXCEPTION 'FAIL [3b] vorherige 0 -> kein Trend, got %', t; END IF;
  RAISE NOTICE 'PASS [3] Markt-Trend: juengste zwei Messungen mit Zahl, Teilung durch 0 abgefangen';

  IF career.fn_salary_annual(4250, 'month') IS DISTINCT FROM 51000::numeric
     OR career.fn_salary_annual(61000, 'year') IS DISTINCT FROM 61000::numeric
     OR career.fn_salary_annual(61000, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [4] Jahresgehalt'; END IF;
  RAISE NOTICE 'PASS [4] Jahresgehalt 12 x Monat, ohne Einheit unbekannt';
END $$;

ROLLBACK;
