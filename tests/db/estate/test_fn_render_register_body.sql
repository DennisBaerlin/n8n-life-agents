-- tests/db/estate/test_fn_render_register_body.sql
-- WS-5: der GETEILTE Register-Body (Rule-of-Three-Extraktion). Prueft die DRY-Garantie
-- (Overview == fn_render_register_body(false), also kein Sektions-Duplikat -> drift-frei), die
-- Maskierung am Body-Level (p_mask true/false) und die System-Steckbrief-Sektion. Self-contained.
BEGIN;

DO $$
DECLARE
  v_overview TEXT;
  v_body     TEXT;
  v_masked   TEXT;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('erika', 'Erika Beispiel', 'owner')
  ON CONFLICT (person_id) DO NOTHING;

  INSERT INTO estate.person_records (person_id, tax_id, pension_insurance_no)
  VALUES ('erika', '12345678901', '12190680M007');
  INSERT INTO estate.system_profile (scope, backup_key_location)
  VALUES ('household', 'Umschlag im Tresor');

  -- ---------- TEST 1: Wrapper-Identitaet (Overview == register_body(false)) = DRY-Garantie ----------
  v_overview := estate.fn_render_estate_overview('estate_overview');
  v_body     := estate.fn_render_register_body(false, 'de');
  IF v_overview IS DISTINCT FROM v_body THEN
    RAISE EXCEPTION 'FAIL [1 Overview != register_body(false) -> Wrapper driftet]'; END IF;
  RAISE NOTICE 'PASS [1] Overview == register_body(false) (kein Sektions-Duplikat)';

  -- ---------- TEST 2: Maskierung am Body-Level (der Binder reicht sie nur durch) ----------
  IF v_body NOT LIKE '%12345678901%' OR v_body NOT LIKE '%12190680M007%' THEN
    RAISE EXCEPTION 'FAIL [2 unmaskierter Body ohne Kennnummern]'; END IF;
  v_masked := estate.fn_render_register_body(true, 'de');
  IF v_masked LIKE '%12345678901%' OR v_masked LIKE '%12190680M007%' THEN
    RAISE EXCEPTION 'FAIL [2 register_body(true) liess Kennnummern durch]'; END IF;
  IF v_masked NOT LIKE '%••••••%' THEN
    RAISE EXCEPTION 'FAIL [2 Masken-Platzhalter fehlt]'; END IF;
  RAISE NOTICE 'PASS [2] p_mask maskiert Steuer-ID/RV-Nr. genau am Body';

  -- ---------- TEST 3: System-Steckbrief-Sektion im geteilten Body ----------
  IF v_body NOT LIKE '%estate.register.system%' OR v_body NOT LIKE '%Umschlag im Tresor%' THEN
    RAISE EXCEPTION 'FAIL [3 System-Steckbrief-Sektion fehlt im Body]'; END IF;
  -- -> erscheint damit auch im Overview (Test 1 == ) und im Binder (test_fn_render_emergency_binder).
  RAISE NOTICE 'PASS [3] System-Steckbrief-Sektion im geteilten Body (Overview + Binder)';
END $$;

ROLLBACK;
