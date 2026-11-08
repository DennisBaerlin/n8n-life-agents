-- tests/db/core/test_fn_app_button_state.sql
-- Knopf „Uebersicht“ erst, wenn Haushalt und alle aktiven Pakete mit Bildschirm fertig oder uebersprungen sind; einmal frei
-- bleibt frei (eine beim Update neue Sektion nimmt ihn nicht weg), nur der Reset nimmt ihn zurueck.
-- Ankuendigung einmal je Chat; der Menue-Auftrag folgt echten Wechseln des Bereichs.
BEGIN;

DO $$
DECLARE r jsonb; g0 bigint; g1 bigint; v_key text;
BEGIN
  DELETE FROM core.notification_state WHERE source IN ('app_button', 'app_intro');
  UPDATE agent.guide_onboarding_state SET status = 'completed';
  UPDATE finance.onboarding_state SET status = 'completed';

  INSERT INTO agent.guide_onboarding_state (section_key, ord, label, status) VALUES ('__abr_core__', 1, 'x', 'completed') ON CONFLICT DO NOTHING;
  INSERT INTO finance.onboarding_state (section_key, ord, label, status) VALUES ('__abr__', 1, 'x', 'completed');
  v_key := '__abr__';
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance', '0.1.0', 'active') ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.package_registry (package, version, status) VALUES ('career', '0.1.0', 'active') ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.app_screens;
  INSERT INTO core.app_screens (screen, package, handler_fn, ord, icon) VALUES ('abr', 'finance', 'finance.fn_app_screen_overview', 10, 'x');

  -- offen -> kein Knopf
  UPDATE finance.onboarding_state SET status = 'unknown' WHERE section_key = v_key;
  IF core.fn_app_button_ready() THEN RAISE EXCEPTION 'FAIL [1] finance offen, trotzdem bereit'; END IF;
  UPDATE agent.guide_onboarding_state SET status = 'unknown';
  UPDATE finance.onboarding_state SET status = 'completed';
  IF core.fn_app_button_ready() THEN RAISE EXCEPTION 'FAIL [2] Haushalt offen, trotzdem bereit'; END IF;

  -- uebersprungen zaehlt
  UPDATE agent.guide_onboarding_state SET status = 'skipped';
  UPDATE finance.onboarding_state SET status = 'skipped';
  IF NOT core.fn_app_button_ready() THEN RAISE EXCEPTION 'FAIL [3] uebersprungen muss reichen'; END IF;

  -- Paket ohne Bildschirm zaehlt nicht
  IF NOT core.fn_app_button_ready() THEN RAISE EXCEPTION 'FAIL [4] Paket ohne Bildschirm hat den Knopf gesperrt'; END IF;

  -- einmal frei bleibt frei: neue offene Sektion
  UPDATE finance.onboarding_state SET status = 'unknown' WHERE section_key = v_key;
  IF NOT core.fn_app_button_ready() THEN RAISE EXCEPTION 'FAIL [5] neue Sektion nahm den Knopf weg'; END IF;

  -- Reset nimmt ihn weg und legt einen Menue-Auftrag an
  g0 := COALESCE((SELECT requested_gen FROM core.menu_refresh), 0);
  PERFORM core.fn_reset_onboarding_state();
  g1 := COALESCE((SELECT requested_gen FROM core.menu_refresh), 0);
  IF g1 <= g0 THEN RAISE EXCEPTION 'FAIL [6] Reset ohne Menue-Auftrag'; END IF;
  IF core.fn_app_button_ready() THEN RAISE EXCEPTION 'FAIL [7] Reset hat den Knopf nicht genommen'; END IF;

  -- Ankuendigung: faellig, bis sie gemerkt ist; je Chat
  IF NOT core.fn_app_intro_pending('111') THEN RAISE EXCEPTION 'FAIL [8] Ankuendigung nicht faellig'; END IF;
  PERFORM core.fn_should_notify('app_intro', '111');
  IF core.fn_app_intro_pending('111') THEN RAISE EXCEPTION 'FAIL [9] Ankuendigung zweimal'; END IF;
  IF NOT core.fn_app_intro_pending('222') THEN RAISE EXCEPTION 'FAIL [10] Latch nicht je Chat'; END IF;

  -- Auftrag beim Wechsel offen <-> fertig, nicht bei jedem Setzen
  UPDATE agent.guide_onboarding_state SET status = 'completed';
  UPDATE finance.onboarding_state SET status = 'completed';
  UPDATE finance.onboarding_state SET status = 'unknown' WHERE section_key = v_key;
  g0 := COALESCE((SELECT requested_gen FROM core.menu_refresh), 0);
  r := core.fn_set_onboarding_section(jsonb_build_object('package', 'finance', 'section_key', v_key, 'status', 'completed'));
  g1 := COALESCE((SELECT requested_gen FROM core.menu_refresh), 0);
  IF (r->>'ok')::boolean IS NOT TRUE OR g1 <= g0 THEN RAISE EXCEPTION 'FAIL [11] fertig ohne Auftrag: %', r; END IF;
  g0 := g1;
  PERFORM core.fn_set_onboarding_section(jsonb_build_object('package', 'finance', 'section_key', v_key, 'status', 'completed'));
  g1 := COALESCE((SELECT requested_gen FROM core.menu_refresh), 0);
  IF g1 <> g0 THEN RAISE EXCEPTION 'FAIL [12] Wiederholung hat einen Auftrag angelegt'; END IF;
  RAISE NOTICE 'PASS Knopf-Regel, Latch, Reset, Ankuendigung, Menue-Auftrag';
END $$;

-- Grants: nur das Auftrags-Fenster ist fuer Paket-Rollen offen
DO $$
BEGIN
  IF has_function_privilege('public', 'core.fn_app_button_ready()', 'EXECUTE') THEN RAISE EXCEPTION 'FAIL [13] button_ready PUBLIC'; END IF;
  IF has_function_privilege('public', 'core.fn_app_intro_pending(text)', 'EXECUTE') THEN RAISE EXCEPTION 'FAIL [14] intro_pending PUBLIC'; END IF;
  IF has_function_privilege('public', 'core.fn_menu_refresh_request()', 'EXECUTE') THEN RAISE EXCEPTION 'FAIL [15] request PUBLIC'; END IF;
END $$;

ROLLBACK;
