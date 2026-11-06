-- tests/db/core/test_fn_context_persons.sql
-- agent.fn_context_persons(base_name) (P2b-2): liefert die person_ids, die einen per_user-Kontext
--   '<base>__<person_id>' in agent.core_contexts (managed_by='agent') haben — das eine Suffix-Enumerations-
--   Primitiv fuer die per-Person-Cron-Schleife (score_jobs/refresh_market_signals) + die generische
--   Advisor-Cron-Faecherung. LITERAL-Prefix-Match (kein Regex/kein LIKE) -> injektions-/wildcard-sicher.
-- Faelle: nur per_user-Suffix-Personen je base; managed_by='agent' Pflicht (seed-Zeile raus); Person mit
--   Profil aber OHNE Plan -> bei base 'career_planning' NICHT enumeriert (aktiv = hat Plan); household-base
--   (kein Suffix) -> 0; Prefix-Kollision/Underscore-Wildcard-Sicherheit (careerXplanning__/career_planningX__).
-- BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;
DO $$
DECLARE
    v_arr text[];
BEGIN
    -- family (2 Personen) — fuer Realismus; fn_context_persons liest family NICHT, nur core_contexts-Namen.
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata, managed_by, package)
    VALUES ('family','t',NULL,'lazy','f',
        jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','as_of','2026-06-11'),
            jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','as_of','2026-06-11')))),
        'agent','core')
    ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

    -- per_user career_planning fuer erika + lena (managed_by='agent' = echte Laufzeit-PII)
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata, managed_by, package)
    VALUES
      ('career_planning__erika','t',NULL,'lazy','plan e', '{}'::jsonb, 'agent','career'),
      ('career_planning__lena', 't',NULL,'lazy','plan l', '{}'::jsonb, 'agent','career'),
      -- Profil-Kontexte (anderer base): lena hat Profil+Plan, kid NUR Profil (kein Plan)
      ('career_profile__lena',  't',NULL,'lazy','prof l', '{}'::jsonb, 'agent','career'),
      ('career_profile__kid',   't',NULL,'lazy','prof k', '{}'::jsonb, 'agent','career'),
      -- managed_by='seed' (kein PII-Laufzeit-Kontext) -> MUSS aus der Enumeration fallen
      ('career_planning__seeded','t',NULL,'lazy','seed', '{}'::jsonb, 'seed','career'),
      -- Prefix-Kollision / Underscore-Wildcard-Sicherheit: duerfen NICHT als 'career_planning'-Person zaehlen
      ('career_planningX__foo', 't',NULL,'lazy','x', '{}'::jsonb, 'agent','career'),
      ('careerXplanning__bar',  't',NULL,'lazy','y', '{}'::jsonb, 'agent','career')
    ON CONFLICT (name) DO NOTHING;

    -- TEST 1: 'career_planning' -> genau {erika, lena} (NICHT kid [nur Profil], NICHT seeded, NICHT Kollisionen)
    SELECT array_agg(person_id ORDER BY person_id) INTO v_arr FROM agent.fn_context_persons('career_planning');
    IF v_arr IS DISTINCT FROM ARRAY['erika','lena'] THEN
        RAISE EXCEPTION 'FAIL [1] career_planning erwartet {erika,lena}, got %', v_arr; END IF;
    RAISE NOTICE 'PASS [1] career_planning -> {erika, lena} (per_user, managed_by=agent)';

    -- TEST 2: Person mit Profil ABER ohne Plan (kid) -> bei base 'career_planning' NICHT enthalten (aktiv=hat-Plan)
    IF 'kid' = ANY(v_arr) THEN RAISE EXCEPTION 'FAIL [2] kid (nur Profil, kein Plan) darf nicht enumeriert sein: %', v_arr; END IF;
    RAISE NOTICE 'PASS [2] Profil-ohne-Plan -> NICHT enumeriert (aktiv = hat Plan)';

    -- TEST 3: anderer base 'career_profile' -> {kid, lena} (eigene Suffix-Menge)
    SELECT array_agg(person_id ORDER BY person_id) INTO v_arr FROM agent.fn_context_persons('career_profile');
    IF v_arr IS DISTINCT FROM ARRAY['kid','lena'] THEN
        RAISE EXCEPTION 'FAIL [3] career_profile erwartet {kid,lena}, got %', v_arr; END IF;
    RAISE NOTICE 'PASS [3] career_profile -> {kid, lena} (base-spezifisch)';

    -- TEST 4: managed_by='seed' wird gefiltert (career_planning__seeded NICHT in [1])
    SELECT array_agg(person_id ORDER BY person_id) INTO v_arr FROM agent.fn_context_persons('career_planning');
    IF 'seeded' = ANY(v_arr) THEN RAISE EXCEPTION 'FAIL [4] managed_by=seed darf nicht enumeriert sein: %', v_arr; END IF;
    RAISE NOTICE 'PASS [4] managed_by=seed -> gefiltert';

    -- TEST 5: Prefix-/Wildcard-Sicherheit: 'career_planningX__foo' + 'careerXplanning__bar' NICHT als career_planning-Person
    IF 'foo' = ANY(v_arr) OR 'bar' = ANY(v_arr) THEN
        RAISE EXCEPTION 'FAIL [5] Prefix-/Wildcard-Kollision enumeriert: %', v_arr; END IF;
    RAISE NOTICE 'PASS [5] Literal-Prefix-Match -> keine Underscore-Wildcard-/Prefix-Kollision';

    -- TEST 6: household-base ohne Suffix-Zeilen (financial_planning) -> 0 Personen
    SELECT array_agg(person_id) INTO v_arr FROM agent.fn_context_persons('financial_planning');
    IF v_arr IS NOT NULL THEN RAISE EXCEPTION 'FAIL [6] household-base erwartet 0 Personen, got %', v_arr; END IF;
    RAISE NOTICE 'PASS [6] household-base (kein Suffix) -> 0 Personen';
END $$;
ROLLBACK;
