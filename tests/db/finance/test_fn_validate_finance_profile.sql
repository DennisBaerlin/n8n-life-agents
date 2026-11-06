-- tests/db/finance/test_fn_validate_finance_profile.sql
-- WS-B1 (Phase 3b): Validator-Stub-Split + generische Validator-Registry. Der finance_profile-
-- Strukturzweig liegt PAKET-besessen in finance.fn_validate_finance_profile(jsonb) (D12). Der Core-
-- Trigger behaelt 'family' inline + dispatcht paket-besessene Sidecars GENERISCH ueber die Registry
-- core.context_validators (NEW.name -> validate_fn -> dyn. EXECUTE) — der Core nennt KEIN Paket mehr
-- hartkodiert. Fehlt die Registry-Zeile (Paket nicht installiert/deinstalliert), validiert Core 'family'
-- weiter, finance_profile-Strukturregeln entfallen still (graceful degradation).
-- Tests: (1) Unit der finance-fn (gueltig/Feld-Fehler/Referenz), (2) Trigger-Dispatch ueber die Registry,
-- (3) Guard-Absence (Registry-Zeile entfernt -> Core-family bleibt, finance_profile-Struktur nicht erzwungen).
-- HINWEIS: db_test seedet core.context_validators NICHT (kein seed_data im Container) -> der Test seedet die
-- Registry-Zeile selbst (self-seedend, BEGIN..ROLLBACK), wie es seed_data.sh im Installer aus dem Manifest tut.
BEGIN;

DO $$
DECLARE
  v_err TEXT;
BEGIN
  -- ---------- Fixture: family (erika+lena), damit der person_id-in-family-Check Daten hat ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by','agent','protected', true, 'render_fn','fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','as_of','2026-06-11'),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ---------- Fixture: Registry-Zeile (Host-Seed-Aequivalent aus packages/finance/manifest.json) ----------
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('finance_profile', 'finance.fn_validate_finance_profile', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn, package = EXCLUDED.package;

  -- ---------- TEST 1: gueltiges finance_profile -> NULL ----------
  v_err := finance.fn_validate_finance_profile(jsonb_build_object('persons', jsonb_build_array(
             jsonb_build_object('person_id','erika','planned_retirement_age',63,'steuerklasse',3,
                                'vorsorgesystem','grv','as_of','2026-06-11'))));
  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [valid]: erwartet NULL, got %', v_err;
  END IF;
  RAISE NOTICE 'PASS finance.fn_validate_finance_profile [gueltiges Profil akzeptiert]';

  -- ---------- TEST 2: facts ohne persons -> NULL (facts optional) ----------
  IF finance.fn_validate_finance_profile('{}'::jsonb) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [no persons]: erwartet NULL';
  END IF;
  RAISE NOTICE 'PASS [facts ohne persons akzeptiert]';

  -- ---------- TEST 3: Steuerklasse ausserhalb 1..6 -> Fehler ----------
  v_err := finance.fn_validate_finance_profile(jsonb_build_object('persons', jsonb_build_array(
             jsonb_build_object('person_id','erika','steuerklasse',9))));
  IF v_err IS NULL OR v_err NOT ILIKE '%steuerklasse%' THEN
    RAISE EXCEPTION 'FAIL [steuerklasse 9]: erwartet steuerklasse-Fehler, got %', v_err;
  END IF;
  RAISE NOTICE 'PASS [Steuerklasse 9 abgewiesen]';

  -- ---------- TEST 4: planned_retirement_age ausserhalb 40..80 -> Fehler ----------
  v_err := finance.fn_validate_finance_profile(jsonb_build_object('persons', jsonb_build_array(
             jsonb_build_object('person_id','erika','planned_retirement_age',30))));
  IF v_err IS NULL OR v_err NOT ILIKE '%planned_retirement_age%' THEN
    RAISE EXCEPTION 'FAIL [retirement 30]: erwartet Range-Fehler, got %', v_err;
  END IF;
  RAISE NOTICE 'PASS [planned_retirement_age 30 abgewiesen]';

  -- ---------- TEST 5: vorsorgesystem nicht im Enum -> Fehler ----------
  v_err := finance.fn_validate_finance_profile(jsonb_build_object('persons', jsonb_build_array(
             jsonb_build_object('person_id','erika','vorsorgesystem','riester'))));
  IF v_err IS NULL OR v_err NOT ILIKE '%vorsorgesystem%' THEN
    RAISE EXCEPTION 'FAIL [vorsorgesystem]: erwartet Enum-Fehler, got %', v_err;
  END IF;
  RAISE NOTICE 'PASS [vorsorgesystem riester abgewiesen]';

  -- ---------- TEST 6: person_id nicht in family (Single-Writer-Referenz) -> Fehler ----------
  -- Phase A: die Referenz prueft GENERISCH der Core-Validator (reservierter Form-Key persons[]), nicht mehr
  -- die finance-fn — die liefert dafuer NULL (keine Doppel-Pruefung).
  v_err := agent.fn_validate_household_facts(jsonb_build_object('persons', jsonb_build_array(
             jsonb_build_object('person_id','ghost'))), 'finance_profile');
  IF v_err IS NULL OR v_err NOT ILIKE '%do not exist in family%' THEN
    RAISE EXCEPTION 'FAIL [unknown person_id]: erwartet family-Referenz-Fehler (Core), got %', v_err;
  END IF;
  IF finance.fn_validate_finance_profile(jsonb_build_object('persons', jsonb_build_array(
       jsonb_build_object('person_id','ghost')))) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [unknown person_id]: finance-fn darf die Referenz nicht mehr selbst pruefen';
  END IF;
  RAISE NOTICE 'PASS [finance_profile referenziert nur family-Personen — Core-Pruefung]';

  -- ---------- TEST 7 (Trigger-Integration): kaputtes finance_profile via Direkt-INSERT -> Exception ----------
  -- Beweist, dass der Core-Trigger die finance-fn ueber die REGISTRY dispatcht (Backstop, auch gegen Direkt-psql).
  BEGIN
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
    VALUES ('finance_profile', 'x', 'finance_advisor', 'lazy', E'## x',
            jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons',
              jsonb_build_array(jsonb_build_object('person_id','erika','steuerklasse',9)))))
    ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
    RAISE EXCEPTION 'FAIL [trigger dispatch]: kaputtes finance_profile akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS [Core-Trigger dispatcht finance_profile an die finance-fn: %]', SQLERRM;
  END;

END $$;

-- ---------- TEST 8 (Guard-Absence): Finance-Paket "deinstalliert" = Registry-Zeile entfernt
--            -> Core validiert family weiter, finance_profile-Struktur wird nicht mehr erzwungen
--            (graceful degradation: kein Registry-Eintrag -> kein Dispatch) ----------
-- Owner-Modell (WS-B1-Redesign): "deinstalliert" heisst Registry-Zeile weg (seed_data/Uninstall),
-- NICHT die fn droppen — der Core kennt das Paket nur ueber die Registry. Eigener DO-Block danach.
DELETE FROM core.context_validators WHERE context_name = 'finance_profile';

DO $$
BEGIN
  -- family-Validierung bleibt unabhaengig vom Finance-Paket: leere persons -> Exception.
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons}', '[]'::jsonb)
    WHERE name = 'family';
    RAISE EXCEPTION 'FAIL [guard-absence family]: leere family.persons akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS [Core validiert family weiter ohne Finance-Paket: %]', SQLERRM;
  END;

  -- finance_profile-Struktur NICHT mehr erzwungen (kaputte Steuerklasse geht durch, kein Dispatch-Ziel).
  -- Die Personen-Referenz bleibt Core-Gesetz (Phase A) -> eine gueltige family-Person verwenden.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('finance_profile', 'x', 'finance_advisor', 'lazy', E'## x',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons',
            jsonb_build_array(jsonb_build_object('person_id','erika','steuerklasse',9)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  RAISE NOTICE 'PASS [Guard-Absence: finance_profile-Strukturregeln entfallen still (Paket weg)]';
END $$;

ROLLBACK;
