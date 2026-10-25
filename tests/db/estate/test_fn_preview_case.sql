-- tests/db/estate/test_fn_preview_case.sql
-- WP3: die HITL-Preview eines Ereignisfalls loest relative Daten EINMAL auf (die Rueckgabe traegt das Datum, das der
--   Tool-Write uebernimmt) und meldet die Intake-Merkmale des Falltyps: intake_facts = wirksam true (Register oder
--   Angabe), unknown_flags = weder Register noch Angabe (genau das fragt der Agent). Self-contained.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ---- relative Daten: "yesterday" -> Tag; leeres knowledge_date = event_date ----
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date','yesterday','bundesland','bayern'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->>'event_date')::date IS DISTINCT FROM core.fn_today() - 1
     OR (v_r->>'knowledge_date')::date IS DISTINCT FROM core.fn_today() - 1 THEN
    RAISE EXCEPTION 'FAIL [relatives event_date: %]', v_r; END IF;
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date','-3 days','knowledge_date','yesterday','bundesland','bayern'));
  IF (v_r->>'knowledge_date')::date IS DISTINCT FROM core.fn_today() - 1 THEN
    RAISE EXCEPTION 'FAIL [relatives knowledge_date: %]', v_r; END IF;
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date','tomorrow','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%future%' THEN RAISE EXCEPTION 'FAIL [Zukunft: %]', v_r; END IF;
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date','vor drei Tagen','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%relative%' THEN RAISE EXCEPTION 'FAIL [Freitext: %]', v_r; END IF;
  RAISE NOTICE 'PASS preview [relative Daten einmal aufgeloest, Zukunft/Freitext abgelehnt]';

  -- ---- Intake: leeres Register -> alle Merkmale des Todesfalls unbekannt ----
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date','yesterday','bundesland','bayern'));
  IF v_r->'unknown_flags' IS DISTINCT FROM '["abroad_or_work_accident","employed","has_will","pension_relevant","tenant"]'::jsonb
     OR v_r->'intake_facts' IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Intake leer: %]', v_r; END IF;
  -- Register kennt Testament + Arbeitgeber, Nutzer sagt "keine Mietwohnung" -> nur noch Rente/Ausland offen
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('hans','testament','exists');
  INSERT INTO estate.person_records (person_id, employer) VALUES ('hans','Beispiel GmbH');
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date','yesterday','bundesland','bayern','flags', jsonb_build_object('tenant', false)));
  IF v_r->'intake_facts' IS DISTINCT FROM '["employed","has_will"]'::jsonb
     OR v_r->'unknown_flags' IS DISTINCT FROM '["abroad_or_work_accident","pension_relevant"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Intake Register + Angabe: %]', v_r; END IF;
  -- Vorsorgefall: nur no_poa/employed sind Merkmale des Typs
  v_r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','incapacity','subject_person_id','hans',
           'event_date','yesterday','bundesland','bayern'));
  IF v_r->'unknown_flags' IS DISTINCT FROM '["no_poa"]'::jsonb OR v_r->'intake_facts' IS DISTINCT FROM '["employed"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Intake Vorsorgefall: %]', v_r; END IF;
  RAISE NOTICE 'PASS preview [intake_facts / unknown_flags aus Register + Angabe je Falltyp]';

  -- ---- create_case uebernimmt dieselben Werte und schreibt nur Nutzer-Aussagen in flags ----
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date', to_char(core.fn_today() - 1, 'YYYY-MM-DD'), 'bundesland','bayern',
           'flags', jsonb_build_object('tenant', false, 'employed', NULL)));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT flags FROM estate.cases WHERE id = (v_r->>'case_id')::bigint) IS DISTINCT FROM '{"tenant":false}'::jsonb
     OR v_r->'unknown_flags' IS DISTINCT FROM '["abroad_or_work_accident","pension_relevant"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [create_case flags/unknown_flags: % / %]', v_r,
      (SELECT flags FROM estate.cases WHERE id = (v_r->>'case_id')::bigint); END IF;
  IF (SELECT status FROM estate.case_tasks WHERE case_id = (v_r->>'case_id')::bigint AND template_key = 'deliver_will') <> 'open' THEN
    RAISE EXCEPTION 'FAIL [Register-Testament -> deliver_will open]'; END IF;
  RAISE NOTICE 'PASS create_case [nur Aussagen in flags, Register wirkt, unknown_flags im Ergebnis]';
END $$;

ROLLBACK;
