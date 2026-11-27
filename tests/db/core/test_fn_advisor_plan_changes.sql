-- tests/db/core/test_fn_advisor_plan_changes.sql
-- Testet agent.fn_advisor_plan_changes: der Themen-Unterschied eines Entwurfs gegen den aktiven Plan derselben (Domain, Person)
-- (neu / geaendert / entfernt, je Thema das Label) und der Kartentext daraus; ohne aktiven Plan = erster Plan.
-- Gleiche Themen mit nur anderem saved_at zaehlen nicht als geaendert.
BEGIN;

DO $$
DECLARE
  v_active INT;
  v_draft  INT;
  v_first  INT;
  v_r      JSONB;
BEGIN
  -- Erster Plan: kein aktiver Plan der Domain
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, plan_md, interview_state)
  VALUES ('__test_chgfirst__', '__test_chg__', 'draft', 1, '',
          jsonb_build_object('goals', jsonb_build_object('topics', jsonb_build_array(jsonb_build_object('topic', 'Ziel', 'content', 'A.')))))
  RETURNING id INTO v_first;
  v_r := agent.fn_advisor_plan_changes(v_first, 'de');
  IF (v_r->>'first')::boolean IS DISTINCT FROM true OR v_r->>'text' IS DISTINCT FROM core.fn_ui_text('core.tpl.plan_changes_first', 'de') THEN
    RAISE EXCEPTION 'FAIL fn_advisor_plan_changes [erster Plan]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_plan_changes [erster Plan]';

  -- Aktiver Plan v1: Ziel, Notreserve, Altes Thema
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, plan_md, interview_state)
  VALUES ('__test_chgdom__', '__test_chg__', 'active', 1, '# v1', jsonb_build_object(
    'goals', jsonb_build_object('topics', jsonb_build_array(
      jsonb_build_object('topic', 'Ziel', 'content', 'Haus in zehn Jahren.', 'saved_at', '2026-01-01'),
      jsonb_build_object('topic', 'Altes Thema', 'content', 'Faellt weg.'))),
    'emergency_reserve', jsonb_build_object('topics', jsonb_build_array(
      jsonb_build_object('topic', 'Notreserve', 'content', 'Drei Monatsausgaben.', 'saved_at', '2026-01-01')))))
  RETURNING id INTO v_active;
  -- Entwurf v2: Ziel geaendert, Notreserve gleich (nur saved_at neu), Altes Thema entfernt, Sparrate neu
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, plan_md, interview_state)
  VALUES ('__test_chgdom__', '__test_chg__', 'draft', 2, '', jsonb_build_object(
    'goals', jsonb_build_object('topics', jsonb_build_array(
      jsonb_build_object('topic', 'Ziel', 'content', 'Haus in acht Jahren.', 'saved_at', '2026-02-01'))),
    'emergency_reserve', jsonb_build_object('topics', jsonb_build_array(
      jsonb_build_object('topic', 'Notreserve', 'content', 'Drei Monatsausgaben.', 'saved_at', '2026-02-01'))),
    'wealth_building', jsonb_build_object('topics', jsonb_build_array(
      jsonb_build_object('topic', 'Sparrate', 'content', 'Monatlich in den ETF.')))))
  RETURNING id INTO v_draft;

  v_r := agent.fn_advisor_plan_changes(v_draft, 'de');
  IF (v_r->>'first')::boolean IS DISTINCT FROM false
     OR v_r->'new' IS DISTINCT FROM '["Sparrate"]'::jsonb
     OR v_r->'changed' IS DISTINCT FROM '["Ziel"]'::jsonb
     OR v_r->'removed' IS DISTINCT FROM '["Altes Thema"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL fn_advisor_plan_changes [Unterschied]: %', v_r;
  END IF;
  IF v_r->>'text' IS DISTINCT FROM concat_ws(' · ',
       core.fn_ui_text('core.tpl.plan_changes_new', 'de', jsonb_build_object('topics', 'Sparrate')),
       core.fn_ui_text('core.tpl.plan_changes_changed', 'de', jsonb_build_object('topics', 'Ziel')),
       core.fn_ui_text('core.tpl.plan_changes_removed', 'de', jsonb_build_object('topics', 'Altes Thema'))) THEN
    RAISE EXCEPTION 'FAIL fn_advisor_plan_changes [Text]: %', v_r->>'text';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_plan_changes [neu / geaendert / entfernt, saved_at zaehlt nicht]';

  -- Unveraenderter Entwurf: keine inhaltliche Aenderung
  UPDATE agent.advisor_plans SET interview_state = (SELECT interview_state FROM agent.advisor_plans WHERE id = v_active) WHERE id = v_draft;
  v_r := agent.fn_advisor_plan_changes(v_draft, 'de');
  IF v_r->'new' <> '[]'::jsonb OR v_r->'changed' <> '[]'::jsonb OR v_r->'removed' <> '[]'::jsonb
     OR v_r->>'text' IS DISTINCT FROM core.fn_ui_text('core.tpl.plan_changes_none', 'de') THEN
    RAISE EXCEPTION 'FAIL fn_advisor_plan_changes [unveraendert]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_plan_changes [unveraendert]';

  -- Viele neue Themen: hoechstens sechs Labels, der Rest als Anzahl
  UPDATE agent.advisor_plans SET interview_state = interview_state || jsonb_build_object('retirement_pension', jsonb_build_object('topics',
           (SELECT jsonb_agg(jsonb_build_object('topic', 'T' || g, 'content', 'x')) FROM generate_series(1, 8) g)))
   WHERE id = v_draft;
  v_r := agent.fn_advisor_plan_changes(v_draft, 'de');
  IF jsonb_array_length(v_r->'new') <> 8
     OR v_r->>'text' IS DISTINCT FROM core.fn_ui_text('core.tpl.plan_changes_new', 'de', jsonb_build_object('topics',
          'T1, T2, T3, T4, T5, T6 ' || core.fn_ui_text('core.tpl.plan_changes_more', 'de', jsonb_build_object('n', 2)))) THEN
    RAISE EXCEPTION 'FAIL fn_advisor_plan_changes [Kappung]: %', v_r->>'text';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_plan_changes [hoechstens sechs Labels je Art]';

  -- Nur was ins Plan-Dokument geht zaehlt: as_of in data, ein geloester offener Punkt mit anderer id, Gross-/Kleinschreibung des
  -- Labels und ein Nicht-Objekt im Zustand aendern nichts; ein Abschnitt, der nur auf einer Seite Themen hat (Altbestand mit
  -- content), heisst mit seinem Anzeigenamen, nie mit dem Schluessel.
  UPDATE agent.advisor_plans SET interview_state = jsonb_build_object(
    'goals', jsonb_build_object('topics', jsonb_build_array(jsonb_build_object('topic', 'Ziel', 'content', 'A.',
       'data', jsonb_build_object('goal', jsonb_build_object('horizon_years', 10, 'as_of', '2026-01-01')),
       'open_points', jsonb_build_array(jsonb_build_object('id', 1, 'text', 'Datum offen'))))),
    'crossborder', jsonb_build_object('content', 'Alter Abschnittstext.'))
   WHERE id = v_active;
  UPDATE agent.advisor_plans SET interview_state = jsonb_build_object(
    'goals', jsonb_build_object('topics', jsonb_build_array(jsonb_build_object('topic', 'ziel ', 'content', 'A.',
       'data', jsonb_build_object('goal', jsonb_build_object('horizon_years', 10, 'as_of', '2026-02-01')),
       'open_points', jsonb_build_array(jsonb_build_object('id', 4, 'text', 'Datum offen'),
                                        jsonb_build_object('id', 5, 'text', 'Erledigt', 'resolved_at', '2026-02-01'))))),
    'crossborder', jsonb_build_object('legacy_content', 'Alter Abschnittstext.', 'topics', jsonb_build_array(jsonb_build_object('topic', 'Ausland', 'content', 'Neu gefasst.'))),
    'kaputt', '"x"'::jsonb)
   WHERE id = v_draft;
  v_r := agent.fn_advisor_plan_changes(v_draft, 'de');
  IF v_r->'new' <> '[]'::jsonb OR v_r->'removed' <> '[]'::jsonb
     OR v_r->'changed' IS DISTINCT FROM jsonb_build_array(core.fn_ui_text('core.plan_section.crossborder', 'de')) THEN
    RAISE EXCEPTION 'FAIL fn_advisor_plan_changes [nur Plan-Inhalt, Abschnittsname]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_plan_changes [as_of, Punkt-ids, Schreibweise egal; Altbestand mit Abschnittsnamen]';

  -- Unbekannte plan_id -> NULL
  IF agent.fn_advisor_plan_changes(-1, 'de') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_advisor_plan_changes [unbekannt]: erwartet NULL';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_plan_changes [unbekannte plan_id -> NULL]';
END $$;

ROLLBACK;
