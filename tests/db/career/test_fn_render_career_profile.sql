-- tests/db/career/test_fn_render_career_profile.sql
-- career.fn_render_career_profile: Header-only Render des career_profile-Sidecars (fn(text)->text),
-- Ableitung "letzter Jobwechsel" render-at-fetch. NULL wenn kein facts-Sidecar.
BEGIN;
DO $$
DECLARE v_hdr TEXT;
BEGIN
  -- keine Zeile -> NULL (Engine rendert dann nur Prosa)
  IF career.fn_render_career_profile('career_profile') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [no row -> NULL]'; END IF;

  -- facts einfuegen (clean -> Core-Denylist passt; Validator nicht registriert -> nur Denylist im Trigger)
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_profile','t',NULL,'lazy','prose','agent','career',
    jsonb_build_object('facts', jsonb_build_object(
      'current_title','IT-Projektmanager','industry','Energiewirtschaft','career_start_date', to_char(CURRENT_DATE - interval '8 years', 'YYYY-MM'),
      'skills', jsonb_build_array(jsonb_build_object('name','Stakeholder-Mgmt','level','advanced','since','2019')),
      'last_job_change_date','2022-01-15',
      '_meta', jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE,'YYYY-MM-DD')))));

  v_hdr := career.fn_render_career_profile('career_profile');
  IF v_hdr IS NULL THEN RAISE EXCEPTION 'FAIL [render NULL trotz facts]'; END IF;
  IF v_hdr NOT LIKE '%IT-Projektmanager%' OR v_hdr NOT LIKE '%Energiewirtschaft%'
     OR v_hdr NOT LIKE '%Berufsstart: % (vor ~8 Jahren)%' OR v_hdr NOT LIKE '%Stakeholder-Mgmt (advanced, seit 2019)%'
     OR v_hdr LIKE '%Berufserfahrung%' THEN
    RAISE EXCEPTION 'FAIL [render content]: %', v_hdr;
  END IF;
  IF v_hdr NOT LIKE '%Letzter Jobwechsel%' THEN
    RAISE EXCEPTION 'FAIL [derived since last change]: %', v_hdr;
  END IF;
  RAISE NOTICE 'PASS test_fn_render_career_profile [no-row NULL + Header + Berufsstart/seit render-at-fetch + Wechsel]';
END $$;
ROLLBACK;
