-- tests/db/core/test_advisor_plans_person_keying.sql
-- P0c DB-Gesetz: advisor_plans ist (domain, person_id)-keyed. person_id NULL = Haushalt (finance-Konvention).
-- Die Partial-UNIQUE-Gesetze + das Versions-Audit gelten je (domain, person_id) — und halten ueber
-- NULLS NOT DISTINCT (PG15+) AUCH fuer die household-NULL-Zeilen (sonst behandelt der Default NULLS DISTINCT
-- zwei NULLs als verschieden -> stiller Verlust des "ein active/draft pro Haushalt"). Das ist der
-- arch-challenge-Pflichttest (Option A): der CONSTRAINT lehnt ab, nicht fn-Logik. Direkte INSERTs (Superuser,
-- kein fn-Gate) pruefen die Constraints selbst.
BEGIN;
DO $$
BEGIN
  -- FK-Ziel: person_id -> agent.persons. Zwei Test-Personen.
  INSERT INTO agent.persons (person_id, full_name, role)
    VALUES ('persona', 'Person A', 'owner'), ('personb', 'Person B', 'partner')
    ON CONFLICT (person_id) DO NOTHING;

  -- ---------- TEST 1 (arch-challenge Pflicht): zwei household-NULL active -> 2. abgelehnt (NULLS NOT DISTINCT) ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
    VALUES ('__test_pk__', NULL, 'h1', 'active', 1);
  BEGIN
    INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
      VALUES ('__test_pk__', NULL, 'h2', 'active', 2);
    RAISE EXCEPTION 'FAIL [1] zweiter household-active (person_id NULL) akzeptiert -> NULLS NOT DISTINCT greift NICHT';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [1] NULLS NOT DISTINCT: zweiter household-active (person_id NULL) abgelehnt (Constraint, nicht fn)';
  END;

  -- ---------- TEST 2: zwei household-NULL draft -> 2. abgelehnt ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
    VALUES ('__test_pk2__', NULL, 'd1', 'draft', 1);
  BEGIN
    INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
      VALUES ('__test_pk2__', NULL, 'd2', 'draft', 2);
    RAISE EXCEPTION 'FAIL [2] zweiter household-draft (NULL) akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [2] NULLS NOT DISTINCT: zweiter household-draft abgelehnt';
  END;

  -- ---------- TEST 3 (per_user): zwei Personen -> je ein Draft derselben Domain koexistieren ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
    VALUES ('__test_pk3__', 'persona', 'pa', 'draft', 1);
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
    VALUES ('__test_pk3__', 'personb', 'pb', 'draft', 1);   -- andere Person -> erlaubt (per_user)
  IF (SELECT count(*) FROM agent.advisor_plans WHERE domain='__test_pk3__' AND status='draft') <> 2 THEN
    RAISE EXCEPTION 'FAIL [3] zwei Personen-Drafts derselben Domain nicht koexistent';
  END IF;
  RAISE NOTICE 'PASS [3] per_user: Person A + B Draft derselben Domain koexistieren';

  -- ---------- TEST 4: zweiter Draft DERSELBEN Person -> abgelehnt (ein Draft pro (domain, person)) ----------
  BEGIN
    INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
      VALUES ('__test_pk3__', 'persona', 'pa2', 'draft', 2);
    RAISE EXCEPTION 'FAIL [4] zweiter Draft derselben (domain, person) akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [4] ein Draft pro (domain, person): zweiter Persona-Draft abgelehnt';
  END;

  -- ---------- TEST 5: Versions-Audit (domain, person_id, version) NULLS NOT DISTINCT haelt fuer NULL ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
    VALUES ('__test_pk5__', NULL, 'v1', 'superseded', 1);
  BEGIN
    INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
      VALUES ('__test_pk5__', NULL, 'v1b', 'superseded', 1);   -- gleiche (domain, NULL, version)
    RAISE EXCEPTION 'FAIL [5] (domain, NULL, version) doppelt akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [5] Versions-Audit (domain, person_id, version) NULLS NOT DISTINCT haelt fuer household-NULL';
  END;

  -- ---------- TEST 6: FK person_id -> agent.persons (unbekannte Person abgelehnt) ----------
  BEGIN
    INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
      VALUES ('__test_pk6__', 'kein_slug_x', 'x', 'draft', 1);
    RAISE EXCEPTION 'FAIL [6] unbekannter person_id-Slug akzeptiert (FK fehlt)';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'PASS [6] FK person_id -> agent.persons: unbekannter Slug abgelehnt';
  END;
END $$;
ROLLBACK;
