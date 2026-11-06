-- tests/db/core/test_persons_projection.sql
-- WS-1 Multi-Member: agent.persons-CQRS-Projektion + FK-Verwaisungs-Schutz.
-- Prueft den Sync-Trigger trg_project_persons (agent.persons_init.sql): family-Write ->
-- agent.persons projiziert; Reconcile-GC entfernt Slugs; FK ON DELETE RESTRICT der finance-
-- Entitaeten blockt das Entfernen einer noch referenzierten Person; name-Gate (nur 'family'
-- projiziert). Persona = fiktiv (Mustermann), kein PII.
-- Pattern: BEGIN ... ROLLBACK; RAISE EXCEPTION = FAIL.
BEGIN;

DO $$
DECLARE
    v_facts3 jsonb := jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','owner_x','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-01-01'),
        jsonb_build_object('person_id','child_x','first_name','Lena', 'last_name','Mustermann','role','child','birth_date','2015-01-01'),
        jsonb_build_object('person_id','partner_x','first_name','Tom','last_name','Mustermann','role','partner','birth_date','1982-01-01')
    ));
    v_facts_no_partner jsonb := jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','owner_x','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-01-01'),
        jsonb_build_object('person_id','child_x','first_name','Lena', 'last_name','Mustermann','role','child','birth_date','2015-01-01')
    ));
    v_facts_no_child jsonb := jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','owner_x','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-01-01')
    ));
    v_cnt INT;
    v_name TEXT;
    v_role TEXT;
BEGIN
    -- ===== (0) Defense-in-Depth (Cold-Eyes A1): NULL-person_id im Array bricht den Reconcile nicht =====
    -- fn_project_persons ist eigenstaendig aufrufbar; ein NULL-Eintrag darf weder crashen (PK-NOT-NULL)
    -- noch den GC-DELETE neutralisieren (NULL in v_keys -> `<> ALL` -> NULL -> stiller No-Op).
    INSERT INTO agent.persons (person_id, full_name, role) VALUES ('stale_x','Stale','child'),('keep_x','Keep','child');
    PERFORM agent.fn_project_persons(jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','keep_x','first_name','Keep'),
        jsonb_build_object('person_id', NULL))));
    IF EXISTS (SELECT 1 FROM agent.persons WHERE person_id = 'stale_x') THEN
        RAISE EXCEPTION 'FAIL [null-robust GC]: stale_x trotz NULL-Eintrag nicht entfernt (GC neutralisiert)'; END IF;
    IF NOT EXISTS (SELECT 1 FROM agent.persons WHERE person_id = 'keep_x') THEN
        RAISE EXCEPTION 'FAIL [null-robust GC]: keep_x nicht projiziert'; END IF;
    DELETE FROM agent.persons WHERE person_id = 'keep_x';  -- aufraeumen vor dem family-Setup
    RAISE NOTICE 'PASS [null-robust GC: NULL-Eintrag uebersprungen, GC korrekt]';

    -- ===== Fixture: family anlegen (Validator + Projektions-Trigger feuern) =====
    DELETE FROM agent.core_contexts WHERE name IN ('family','finance_profile');  -- db_test: protected_contexts leer
    INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
    VALUES ('family', 'test', 'static', 'prose', jsonb_build_object('facts', v_facts3), 'agent', 'core');

    -- ===== (1) Projektion bei INSERT: 3 Personen in agent.persons =====
    SELECT count(*) INTO v_cnt FROM agent.persons WHERE person_id IN ('owner_x','child_x','partner_x');
    IF v_cnt <> 3 THEN RAISE EXCEPTION 'FAIL [projection insert]: erwartet 3 projizierte Personen, got %', v_cnt; END IF;
    SELECT full_name, role INTO v_name, v_role FROM agent.persons WHERE person_id = 'child_x';
    IF v_name IS DISTINCT FROM 'Lena Mustermann' THEN RAISE EXCEPTION 'FAIL [projection full_name]: got %', COALESCE(v_name,'<null>'); END IF;
    IF v_role IS DISTINCT FROM 'child' THEN RAISE EXCEPTION 'FAIL [projection role]: got %', COALESCE(v_role,'<null>'); END IF;
    RAISE NOTICE 'PASS [projection insert: 3 Personen, full_name+role korrekt]';

    -- ===== (2) Re-Projektion bei full_name-Aenderung (stabiler Slug, kein FK-Effekt) =====
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons,1,last_name}', '"Beispiel"'::jsonb)
    WHERE name = 'family';
    SELECT full_name INTO v_name FROM agent.persons WHERE person_id = 'child_x';
    IF v_name IS DISTINCT FROM 'Lena Beispiel' THEN RAISE EXCEPTION 'FAIL [re-projection]: full_name nicht aktualisiert, got %', COALESCE(v_name,'<null>'); END IF;
    SELECT count(*) INTO v_cnt FROM agent.persons WHERE person_id IN ('owner_x','child_x','partner_x');
    IF v_cnt <> 3 THEN RAISE EXCEPTION 'FAIL [re-projection]: Personenzahl veraendert (% statt 3)', v_cnt; END IF;
    RAISE NOTICE 'PASS [re-projection: full_name aktualisiert, Slug stabil]';

    -- ===== (3) Reconcile-GC: unreferenzierte Person entfernen -> verschwindet aus agent.persons =====
    UPDATE agent.core_contexts
    SET metadata = jsonb_build_object('facts', v_facts_no_partner)
    WHERE name = 'family';
    IF EXISTS (SELECT 1 FROM agent.persons WHERE person_id = 'partner_x') THEN
        RAISE EXCEPTION 'FAIL [reconcile-GC]: partner_x nicht entfernt'; END IF;
    SELECT count(*) INTO v_cnt FROM agent.persons WHERE person_id IN ('owner_x','child_x','partner_x');
    IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [reconcile-GC]: erwartet 2 Personen, got %', v_cnt; END IF;
    RAISE NOTICE 'PASS [reconcile-GC: unreferenzierte Person entfernt]';

    -- ===== (4) FK ON DELETE RESTRICT: referenzierte Person nicht entfernbar =====
    -- Kind-Depot (cash, owner=child_x) anlegen -> dann child_x aus family entfernen -> RESTRICT.
    INSERT INTO finance.accounts (name, account_type, owner_person_id)
    VALUES ('__test_kind_depot__', 'cash', 'child_x');
    BEGIN
        UPDATE agent.core_contexts
        SET metadata = jsonb_build_object('facts', v_facts_no_child)
        WHERE name = 'family';
        RAISE EXCEPTION 'FAIL [FK-RESTRICT]: child_x liess sich entfernen, obwohl ein Konto sie referenziert';
    EXCEPTION
        WHEN foreign_key_violation THEN NULL;  -- erwartet: der Reconcile-DELETE blockt
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
            RAISE EXCEPTION 'FAIL [FK-RESTRICT]: unerwarteter Fehler statt foreign_key_violation: %', SQLERRM;
    END;
    -- child_x ist noch da (Rollback des family-Writes)
    IF NOT EXISTS (SELECT 1 FROM agent.persons WHERE person_id = 'child_x') THEN
        RAISE EXCEPTION 'FAIL [FK-RESTRICT]: child_x nach geblocktem Entfernen verschwunden'; END IF;
    RAISE NOTICE 'PASS [FK-RESTRICT: referenzierte Person nicht aus family entfernbar]';

    -- ===== (5) name-Gate: ein NICHT-family-Write projiziert nicht =====
    -- finance_profile referenziert eine existierende family-Person -> valide; agent.persons unveraendert.
    INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
    VALUES ('finance_profile', 'test', 'lazy', 'prose',
            jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
                jsonb_build_object('person_id','owner_x')))), 'agent', 'finance');
    SELECT count(*) INTO v_cnt FROM agent.persons WHERE person_id IN ('owner_x','child_x','partner_x');
    IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [name-gate]: finance_profile-Write veraenderte agent.persons (% statt 2)', v_cnt; END IF;
    RAISE NOTICE 'PASS [name-gate: nur family projiziert]';

    -- ===== (6) WP-5b: FEHLENDER persons-Schlüssel (Prosa-only-Update) -> No-Op (Partial-Write-Schutz) =====
    SELECT count(*) INTO v_cnt FROM agent.persons;
    PERFORM agent.fn_project_persons('{"note":"prosa ohne persons"}'::jsonb);   -- kein persons-Schlüssel
    IF (SELECT count(*) FROM agent.persons) IS DISTINCT FROM v_cnt THEN
        RAISE EXCEPTION 'FAIL [WP-5b absent]: fehlender persons-Schlüssel veränderte agent.persons (Wipe statt No-Op)'; END IF;
    RAISE NOTICE 'PASS [WP-5b: fehlender persons-Schlüssel -> No-Op (kein versehentliches Wipe)]';

    -- ===== (7) WP-5b: PRÄSENTES leeres Array -> Full-Wipe (bewusste Voll-Entfernung, keine Stale-Zeilen) =====
    -- Die FK-referenzierte child_x würde den Wipe sonst per RESTRICT blocken -> die Personen-Referenz des Kontos
    -- lösen (owner_person_id = NULL = Haushalt; das Konto selbst hat eine account_balances-Zeile und bleibt),
    -- dann alle Personen bewusst per leerem Array entfernen.
    UPDATE finance.accounts SET owner_person_id = NULL WHERE name = '__test_kind_depot__';
    PERFORM agent.fn_project_persons('{"persons":[]}'::jsonb);
    IF EXISTS (SELECT 1 FROM agent.persons WHERE person_id IN ('owner_x','child_x')) THEN
        RAISE EXCEPTION 'FAIL [WP-5b empty]: leeres Array hat die projizierten Personen NICHT entfernt (Stale-Drift)'; END IF;
    RAISE NOTICE 'PASS [WP-5b: präsentes leeres Array -> Full-Wipe (Voll-Entfernung, kein Stale)]';
END $$;

ROLLBACK;
