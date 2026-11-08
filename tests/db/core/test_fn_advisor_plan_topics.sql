-- tests/db/core/test_fn_advisor_plan_topics.sql
-- Finanzplan in kleinen Themen + Gesamtcheck (2026-11-07):
--   * agent.fn_advisor_save_section mit topic: Upsert in interview_state[key].topics[] (Reihenfolge der ersten Speicherung,
--     gleiche Bezeichnung ohne Gross-/Kleinschreibung ersetzt), data je Thema (Abschnitts-data = Alt-data || Themen-data,
--     derselbe Block in zwei Themen -> block_in_two_topics), Alt-content -> legacy_content + Kartennotiz, Save ohne topic
--     behaelt topics, Post-State topics/topic_replaced;
--   * Laengen-Gesetz advisor.topic_max_chars (Lookup Domain -> Paket ueber core.advisors, E2E-Domain -> echte Domain):
--     ohne topic -> topic_required, zu lang -> topic_too_long {max, length}; Paket ohne Wert (career) unveraendert;
--   * core.fn_advisor_read_plan rendert content aus den Themen, legacy_content nicht im content;
--   * agent.fn_advisor_publish_plan mit advisor.final_check_required: check_findings Pflicht (final_check_missing, auch
--     E2E-Domain), outcome je Fund (final_check_open, index), [] erlaubt, gespeichert, Kartenzeilen mit DB-Zahlen.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r       jsonb;
  v_state jsonb;
  v_row   record;
  v_pid   int;
BEGIN
  -- Domain -> Paket: finance-Domain + E2E-Domain lesen die finance-Config; eine career-Domain hat keinen Wert.
  DELETE FROM core.advisors WHERE domain IN ('__tp_fin__', '__tp_car__');
  INSERT INTO core.advisors (domain, plan_context, review_fn, package) VALUES
    ('__tp_fin__', '__tp_fin___planning', 'finance.fn_advisor_review', 'finance'),
    ('__tp_car__', '__tp_car___planning', 'career.fn_advisor_review', 'career');
  INSERT INTO core.config (category, key, value, package, value_type, minimum, maximum)
  VALUES ('advisor', 'topic_max_chars', '300', 'finance', 'integer', 300, 3500)
  ON CONFLICT (category, key) DO UPDATE SET value = '300';
  INSERT INTO core.config (category, key, value, package, value_type)
  VALUES ('advisor', 'final_check_required', 'true', 'finance', 'boolean')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true';
  DELETE FROM agent.advisor_plans WHERE domain IN ('__tp_fin__', '__tp_car__', '__e2e___tp_fin____');

  -- ---------- 1) Laengen-Gesetz ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','risk_protection',
         'section_content','Haftpflicht vorhanden.'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'topic_required' THEN
    RAISE EXCEPTION 'FAIL [1 topic_required]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','risk_protection',
         'topic','Haftpflicht','section_content', repeat('x', 301)));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'topic_too_long'
     OR jsonb_typeof(r->'max') <> 'number' OR (r->>'max')::int <> 300 OR (r->>'length')::int <> 301 THEN
    RAISE EXCEPTION 'FAIL [1 topic_too_long]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','risk_protection',
         'topic', repeat('t', 61),'section_content','x'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 topic > 60]: %', r; END IF;
  -- E2E-Domain liest die Config der echten Domain
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__e2e___tp_fin____','section_key','risk_protection',
         'section_content','x'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'topic_required' THEN
    RAISE EXCEPTION 'FAIL [1 E2E-Domain]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain IN ('__tp_fin__', '__e2e___tp_fin____')) THEN
    RAISE EXCEPTION 'FAIL [1 Ablehnung schrieb einen Draft]'; END IF;
  -- Paket ohne Wert (career): ohne topic und lang -> unveraendert ok
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_car__','section_key','targets',
         'section_content', repeat('c', 4000)));
  IF (r->>'ok')::boolean IS NOT TRUE OR r ? 'topics' AND jsonb_array_length(r->'topics') <> 0 THEN
    RAISE EXCEPTION 'FAIL [1 career unveraendert]: %', r; END IF;
  RAISE NOTICE 'PASS [1 Laengen-Gesetz]';

  -- ---------- 2) Themen speichern, Reihenfolge, Ersetzen ohne Gross-/Kleinschreibung ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','risk_protection',
         'topic','  Berufsunfähigkeit ','section_content','Keine BU vorhanden, Lücke.'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'topics' <> '["Berufsunfähigkeit"]'::jsonb OR (r->>'topic_replaced')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [2 erstes Thema]: %', r; END IF;
  v_pid := (r->>'plan_id')::int;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','risk_protection',
         'topic','Todesfall','section_content','Risikoleben 200.000 € empfohlen.'));
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','risk_protection',
         'topic','berufsunfähigkeit','section_content','BU bis 67 mit 2.000 € abschließen.'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'topics' <> '["berufsunfähigkeit","Todesfall"]'::jsonb
     OR (r->>'topic_replaced')::boolean IS NOT TRUE OR (r->>'section_count')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [2 ersetzen]: %', r; END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_pid;
  IF jsonb_array_length(v_state->'risk_protection'->'topics') <> 2
     OR v_state->'risk_protection'->'topics'->0->>'content' <> 'BU bis 67 mit 2.000 € abschließen.'
     OR v_state->'risk_protection' ? 'content' OR v_state->'risk_protection' ? 'legacy_content'
     OR NOT (v_state->'risk_protection'->'topics'->0 ? 'saved_at') THEN
    RAISE EXCEPTION 'FAIL [2 Speicherform]: %', v_state; END IF;
  RAISE NOTICE 'PASS [2 Themen: Reihenfolge + Ersetzen]';

  -- ---------- 3) data je Thema + Kollision ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','wealth_building',
         'topic','Aufteilung','section_content','85 % Welt-ETF, 15 % Festgeld.',
         'section_data', '{"target_allocation":{"rebalance_drift_pp":5}}'));
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','wealth_building',
         'topic','Gleitpfad','section_content','Ab 55 Aktienquote senken.',
         'section_data', jsonb_build_object('glidepath', jsonb_build_object('start_age', 55))));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 zweites Thema mit Block]: %', r; END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_pid;
  IF NOT (v_state->'wealth_building'->'data' ? 'target_allocation') OR NOT (v_state->'wealth_building'->'data' ? 'glidepath')
     OR (v_state->'wealth_building'->'topics'->1->'data'->'glidepath'->>'as_of')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL [3 Abschnitts-data aus Themen]: %', v_state->'wealth_building'; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','wealth_building',
         'topic','Steuer','section_content','Freistellungsauftrag nutzen.',
         'section_data', jsonb_build_object('glidepath', jsonb_build_object('start_age', 60))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'block_in_two_topics' THEN
    RAISE EXCEPTION 'FAIL [3 block_in_two_topics]: %', r; END IF;
  -- dasselbe Thema mit seinem eigenen Block neu speichern = Ersetzen, keine Kollision; ohne Block faellt er weg
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','wealth_building',
         'topic','GLEITPFAD','section_content','Ab 60 Aktienquote senken.',
         'section_data', jsonb_build_object('glidepath', jsonb_build_object('start_age', 60))));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 eigener Block ersetzt]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','wealth_building',
         'topic','Gleitpfad','section_content','Kein Gleitpfad.'));
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_pid;
  IF v_state->'wealth_building'->'data' ? 'glidepath' OR NOT (v_state->'wealth_building'->'data' ? 'target_allocation') THEN
    RAISE EXCEPTION 'FAIL [3 Block mit dem Thema entfernt]: %', v_state->'wealth_building'; END IF;
  RAISE NOTICE 'PASS [3 data je Thema + Kollision]';

  -- ---------- 4) Alt-Abschnitt (vor diesem Release) -> legacy_content + Kartennotiz ----------
  UPDATE agent.advisor_plans
     SET interview_state = interview_state || jsonb_build_object('debts_loans', jsonb_build_object(
           'content','Alter Gesamttext zu allen Krediten.', 'data', jsonb_build_object('goal', jsonb_build_object('x', 1)),
           'saved_at', '2026-10-01T10:00:00Z'))
   WHERE id = v_pid;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','debts_loans',
         'topic','Kredit Wohnung','section_content','Sondertilgung 5 % jährlich nutzen.'));
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l
                                                   WHERE l->>'kind' = 'note' AND l->>'value' = 'core.hitl.plan_legacy_replaced') THEN
    RAISE EXCEPTION 'FAIL [4 Notiz]: %', r; END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_pid;
  IF v_state->'debts_loans'->>'legacy_content' IS DISTINCT FROM 'Alter Gesamttext zu allen Krediten.'
     OR v_state->'debts_loans' ? 'content' OR NOT (v_state->'debts_loans'->'data' ? 'goal') THEN
    RAISE EXCEPTION 'FAIL [4 legacy]: %', v_state->'debts_loans'; END IF;
  -- ein Thema uebernimmt den Alt-Block; laesst es ihn spaeter weg, kommt er nicht aus legacy_data zurueck
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','debts_loans',
         'topic','Kredit Wohnung','section_content','Sondertilgung 5 % jährlich nutzen.',
         'section_data', jsonb_build_object('goal', jsonb_build_object('x', 2))));
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','debts_loans',
         'topic','Kredit Wohnung','section_content','Sondertilgung 5 % jährlich nutzen.'));
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_pid;
  IF v_state->'debts_loans' ? 'data' OR v_state->'debts_loans'->'legacy_data' ? 'goal' THEN
    RAISE EXCEPTION 'FAIL [4 Alt-Block kam zurueck]: %', v_state->'debts_loans'; END IF;
  -- zweites Thema: keine Notiz mehr
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_fin__','section_key','debts_loans',
         'topic','Tilgungsregel','section_content','Teuerster Kredit zuerst.'));
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = 'core.hitl.plan_legacy_replaced') THEN
    RAISE EXCEPTION 'FAIL [4 Notiz zweimal]: %', r; END IF;
  RAISE NOTICE 'PASS [4 legacy_content + Kartennotiz]';

  -- ---------- 5) Save ohne topic (Paket ohne Config) behaelt topics ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_car__','section_key','targets','topic','Zielrolle',
         'section_content','Data Analyst.'));
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__tp_car__','section_key','targets',
         'section_content','Gesamttext neu.'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'topics' <> '["Zielrolle"]'::jsonb THEN RAISE EXCEPTION 'FAIL [5 Post-State]: %', r; END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE domain = '__tp_car__' AND status = 'draft';
  IF v_state->'targets'->>'content' <> 'Gesamttext neu.' OR jsonb_array_length(v_state->'targets'->'topics') <> 1 THEN
    RAISE EXCEPTION 'FAIL [5 topics behalten]: %', v_state; END IF;
  RAISE NOTICE 'PASS [5 Save ohne topic behaelt topics]';

  -- ---------- 6) Lesen: content aus den Themen, legacy nicht im content ----------
  SELECT * INTO v_row FROM core.fn_advisor_read_plan('__tp_fin__') WHERE status = 'draft';
  IF v_row.interview_state->'risk_protection'->>'content'
       IS DISTINCT FROM E'berufsunfähigkeit: BU bis 67 mit 2.000 € abschließen.\n\nTodesfall: Risikoleben 200.000 € empfohlen.'
     OR v_row.interview_state->'debts_loans'->>'content' LIKE '%Alter Gesamttext%'
     OR v_row.interview_state->'debts_loans'->>'legacy_content' IS DISTINCT FROM 'Alter Gesamttext zu allen Krediten.'
     OR jsonb_array_length(v_row.interview_state->'risk_protection'->'topics') <> 2 THEN
    RAISE EXCEPTION 'FAIL [6 read_plan]: %', v_row.interview_state; END IF;
  -- gespeichert bleibt kein zweiter Text
  IF (SELECT interview_state->'risk_protection' ? 'content' FROM agent.advisor_plans WHERE id = v_pid) THEN
    RAISE EXCEPTION 'FAIL [6 content gespeichert]'; END IF;
  RAISE NOTICE 'PASS [6 read_plan rendert Themen]';

  -- ---------- 7) Gesamtcheck beim Veroeffentlichen ----------
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'final_check_missing' THEN
    RAISE EXCEPTION 'FAIL [7 missing]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan','check_findings','','check_passes',''));
  IF r->>'code' IS DISTINCT FROM 'final_check_missing' THEN RAISE EXCEPTION 'FAIL [7 leerer String = fehlt]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan','check_passes',1,
         'check_findings', jsonb_build_array(jsonb_build_object('text','BU fehlt','outcome','resolved'),
                                             jsonb_build_object('text','Sparplan ohne Zufluss','outcome','später'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'final_check_open' OR (r->>'index')::int <> 2 THEN
    RAISE EXCEPTION 'FAIL [7 open]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan',
         'check_findings', '[]'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 check_passes fehlt]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan','check_passes',0,
         'check_findings', '[]'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 check_passes 0]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan','check_passes','99999999999','check_findings','[]'));
  IF r->>'code' IS DISTINCT FROM 'final_check_invalid' THEN RAISE EXCEPTION 'FAIL [7 check_passes zu gross]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan','check_passes','1',
         'check_findings', jsonb_build_array(jsonb_build_object('text','','outcome','resolved'))));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 leerer Text]: %', r; END IF;
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__e2e___tp_fin____','plan_md','# Plan'));
  IF r->>'code' IS DISTINCT FROM 'final_check_missing' THEN
    RAISE EXCEPTION 'FAIL [7 E2E-Domain]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain = '__tp_fin__' AND status = 'active') THEN
    RAISE EXCEPTION 'FAIL [7 Ablehnung veroeffentlichte]'; END IF;
  -- [] ist ausdruecklich "keine Funde"
  r := core.fn_dry_run('agent.fn_advisor_publish_plan(jsonb)'::regprocedure, jsonb_build_object('domain','__tp_fin__',
         'plan_md','# Plan','check_passes','1','check_findings','[]'));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l
                    WHERE l->>'label' = 'core.label.final_check' AND l->>'value' = 'core.tpl.final_check_clean'
                      AND (l->'params'->>'passes')::int = 1) THEN
    RAISE EXCEPTION 'FAIL [7 [] erlaubt]: %', r; END IF;
  -- echte Funde: Zahlen aus der DB, jeder bewusst offene Punkt als eigene Zeile, gespeichert
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_fin__','plan_md','# Plan','check_passes',2,
         'check_findings', '[{"text":"BU fehlt","outcome":"resolved"},{"text":"Sparplan läuft nach Zuflussende weiter","outcome":"resolved"},'
                        || '{"text":"Testament offen","outcome":"deferred"},{"text":"Hohe Aktienquote trotz kurzer Frist","outcome":"accepted"}]'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [7 publish]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l
                 WHERE l->>'label' = 'core.label.final_check' AND l->>'value' = 'core.tpl.final_check_counts'
                   AND (l->'params'->>'n')::int = 4 AND (l->'params'->>'passes')::int = 2
                   AND (l->'params'->>'resolved')::int = 2 AND (l->'params'->>'open')::int = 2)
     OR (SELECT count(*) FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'kind' = 'raw') <> 2
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'kind' = 'raw' AND l->>'value' = 'Testament offen') THEN
    RAISE EXCEPTION 'FAIL [7 Kartenzeilen]: %', r; END IF;
  SELECT check_passes, check_findings INTO v_row FROM agent.advisor_plans WHERE id = v_pid;
  IF v_row.check_passes <> 2 OR jsonb_array_length(v_row.check_findings) <> 4 OR v_row.check_findings->2->>'outcome' <> 'deferred' THEN
    RAISE EXCEPTION 'FAIL [7 gespeichert]: %', to_jsonb(v_row); END IF;
  -- Paket ohne Pflicht (career): ohne check_findings unveraendert
  r := agent.fn_advisor_publish_plan(jsonb_build_object('domain','__tp_car__','plan_md','# Karriere'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [7 career ohne Pflicht]: %', r; END IF;
  RAISE NOTICE 'PASS [7 Gesamtcheck]';

  -- ---------- 8) Form-CHECK auf advisor_plans ----------
  BEGIN
    UPDATE agent.advisor_plans SET check_findings = '[]', check_passes = NULL WHERE id = v_pid;
    RAISE EXCEPTION 'FAIL [8 check_passes ohne findings akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    UPDATE agent.advisor_plans SET check_findings = '{"a":1}', check_passes = 1 WHERE id = v_pid;
    RAISE EXCEPTION 'FAIL [8 kein Array akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS [8 Form-CHECK]';
END $$;

ROLLBACK;
