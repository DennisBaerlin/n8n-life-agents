-- ============================================================
-- test_fn_instantiate_case_tasks -- Materialisierer der Fall-Checkliste (create_case + set_case rufen ihn)
--   Gesetz: kein Fall -> RAISE; idempotent (keine Dubletten, kein NULL-subject_ref); due_date immer neu gerechnet;
--   title/detail = Snapshot; Reconcile nur fuer status_source='system' (Merkmal an -> open, Merkmal weg -> n.a.),
--   vom Nutzer gesetzte Status und manuelle Tasks (template_key NULL) bleiben unberuehrt.
--   Faelle werden direkt eingefuegt (Datum fest, die fn rechnet nur aus den Fall-Feldern).
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_case   BIGINT;
    v_n1     INT;
    v_n2     INT;
    v_due1   DATE;
    v_due2   DATE;
    v_manual BIGINT;
    v_caught BOOLEAN := false;
BEGIN
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
    VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
        jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
            jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
    ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

    -- Fall existiert nicht -> echte Ausnahme
    BEGIN
        PERFORM estate.fn_instantiate_case_tasks(-1);
    EXCEPTION WHEN OTHERS THEN
        v_caught := SQLERRM LIKE '%case -1 not found%';
    END;
    IF NOT v_caught THEN RAISE EXCEPTION 'FAIL [kein Fall]: unbekannte case_id muss RAISEn'; END IF;
    RAISE NOTICE 'PASS [kein Fall]: RAISE bei unbekannter case_id';

    INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland, flags)
    VALUES ('death', 'hans', DATE '2024-01-15', DATE '2024-01-15', 'bayern', '{}'::jsonb)
    RETURNING id INTO v_case;

    -- erster Lauf: offene UND n.a.-Tasks, kein NULL-subject_ref
    PERFORM estate.fn_instantiate_case_tasks(v_case);
    SELECT count(*) INTO v_n1 FROM estate.case_tasks WHERE case_id = v_case;
    IF v_n1 < 5 OR NOT EXISTS (SELECT 1 FROM estate.case_tasks WHERE case_id = v_case AND status = 'open')
       OR NOT EXISTS (SELECT 1 FROM estate.case_tasks WHERE case_id = v_case AND status = 'not_applicable') THEN
        RAISE EXCEPTION 'FAIL [erster Lauf]: % Tasks, erwartet >= 5 mit offenen und n.a.', v_n1;
    END IF;
    IF EXISTS (SELECT 1 FROM estate.case_tasks WHERE case_id = v_case AND subject_ref IS NULL) THEN
        RAISE EXCEPTION 'FAIL [erster Lauf]: NULL subject_ref';
    END IF;
    RAISE NOTICE 'PASS [erster Lauf]: % Tasks, offene + n.a.', v_n1;

    -- idempotent
    PERFORM estate.fn_instantiate_case_tasks(v_case);
    SELECT count(*) INTO v_n2 FROM estate.case_tasks WHERE case_id = v_case;
    IF v_n2 <> v_n1 THEN RAISE EXCEPTION 'FAIL [idempotent]: % -> % Tasks', v_n1, v_n2; END IF;
    RAISE NOTICE 'PASS [idempotent]: zweiter Lauf legt nichts neu an';

    -- Merkmal an (Nutzer-Aussage tenant) -> tenancy kippt von n.a. auf open (system-gesetzt)
    IF (SELECT status FROM estate.case_tasks WHERE case_id = v_case AND template_key = 'tenancy') <> 'not_applicable' THEN
        RAISE EXCEPTION 'FAIL [Reconcile Vorzustand]: tenancy ohne Merkmal muss n.a. sein';
    END IF;
    UPDATE estate.cases SET flags = jsonb_build_object('tenant', true) WHERE id = v_case;
    PERFORM estate.fn_instantiate_case_tasks(v_case);
    IF (SELECT status FROM estate.case_tasks WHERE case_id = v_case AND template_key = 'tenancy') <> 'open' THEN
        RAISE EXCEPTION 'FAIL [Reconcile an]: tenancy muss nach tenant=true open sein';
    END IF;
    RAISE NOTICE 'PASS [Reconcile an]: Merkmal wahr -> n.a. wird open';

    -- Merkmal zurueckgenommen -> open (system) kippt zurueck auf n.a.
    UPDATE estate.cases SET flags = '{}'::jsonb WHERE id = v_case;
    PERFORM estate.fn_instantiate_case_tasks(v_case);
    IF (SELECT status FROM estate.case_tasks WHERE case_id = v_case AND template_key = 'tenancy') <> 'not_applicable' THEN
        RAISE EXCEPTION 'FAIL [Reconcile aus]: tenancy muss nach Rücknahme wieder n.a. sein';
    END IF;
    RAISE NOTICE 'PASS [Reconcile aus]: Merkmal weg -> open wird n.a.';

    -- vom Nutzer gesetzter Status bleibt, auch wenn die Bedingung wechselt
    UPDATE estate.case_tasks SET status = 'done', done_at = now(), status_source = 'user'
     WHERE case_id = v_case AND template_key = 'tenancy';
    UPDATE estate.cases SET flags = jsonb_build_object('tenant', true) WHERE id = v_case;
    PERFORM estate.fn_instantiate_case_tasks(v_case);
    IF (SELECT status FROM estate.case_tasks WHERE case_id = v_case AND template_key = 'tenancy') <> 'done' THEN
        RAISE EXCEPTION 'FAIL [Nutzer-Status]: ein vom Nutzer erledigter Task wurde vom Reconcile angefasst';
    END IF;
    RAISE NOTICE 'PASS [Nutzer-Status]: status_source user bleibt';

    -- due_date wird immer neu gerechnet, title = Snapshot
    SELECT due_date INTO v_due1 FROM estate.case_tasks WHERE case_id = v_case AND template_key = 'sterbefallanzeige';
    UPDATE estate.case_tasks SET title = 'Eingefrorener Titel' WHERE case_id = v_case AND template_key = 'sterbefallanzeige';
    UPDATE estate.cases SET event_date = DATE '2024-02-20', knowledge_date = DATE '2024-02-20' WHERE id = v_case;
    PERFORM estate.fn_instantiate_case_tasks(v_case);
    SELECT due_date INTO v_due2 FROM estate.case_tasks WHERE case_id = v_case AND template_key = 'sterbefallanzeige';
    IF v_due1 IS NOT DISTINCT FROM v_due2 THEN
        RAISE EXCEPTION 'FAIL [due_date]: Frist unveraendert (% -> %) trotz neuem Todesdatum', v_due1, v_due2;
    END IF;
    IF (SELECT title FROM estate.case_tasks WHERE case_id = v_case AND template_key = 'sterbefallanzeige') <> 'Eingefrorener Titel' THEN
        RAISE EXCEPTION 'FAIL [Snapshot]: title wurde ueberschrieben';
    END IF;
    RAISE NOTICE 'PASS [due_date/Snapshot]: Frist % -> %, title bleibt', v_due1, v_due2;

    -- manuelle Task (template_key NULL) wird nie angefasst, auch nicht auf n.a. gekippt
    INSERT INTO estate.case_tasks (case_id, phase, title) VALUES (v_case, 'later', 'Eigene Aufgabe') RETURNING id INTO v_manual;
    PERFORM estate.fn_instantiate_case_tasks(v_case);
    IF (SELECT status FROM estate.case_tasks WHERE id = v_manual) <> 'open'
       OR (SELECT count(*) FROM estate.case_tasks WHERE case_id = v_case) <> v_n1 + 1 THEN
        RAISE EXCEPTION 'FAIL [manuelle Task]: wurde veraendert oder Task-Zahl stimmt nicht';
    END IF;
    RAISE NOTICE 'PASS [manuelle Task]: bleibt offen, Reconcile fasst sie nicht an';
END $$;
ROLLBACK;
