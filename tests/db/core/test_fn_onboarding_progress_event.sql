-- tests/db/core/test_fn_onboarding_progress_event.sql
-- core.fn_onboarding_progress_event (Roter Faden): die Einmal-Ereignisse NACH einem Onboarding-Schritt.
--   * send_all_done   — der Schritt hat den letzten fuer die Person offenen Bereich geschlossen; genau EINMAL je
--                       Person (Latch 'onboarding'/'all_done:<pid>'), re-armt, sobald wieder etwas offen ist.
--   * send_learn_offer — nur fuer den Owner, nur zusammen mit send_all_done, nur wenn learn_context AUS ist.
--   * member_chats    — "Es kann losgehen": der Haushalt (core) ist gerade fertig geworden -> die gepairten
--                       Mitglieder; genau EINMAL ueberhaupt (Latch 'household_ready', kein Re-Arm).
--   Ohne area_completed_now (blosses Markieren) sendet die fn nie etwas (kein Ueberraschungs-Send auf Bestands-
--   installationen, deren Onboarding schon lange fertig ist).
-- db_test hat KEIN seed_data -> family/registry/sections self-seeden. BEGIN..ROLLBACK.
-- Aufrufer ist nur core.sub_onboarding_progress (Core-Cred) -> kein Paket-Rollen-Perspektiv-Test noetig.
BEGIN;

DO $$
DECLARE r JSONB;
BEGIN
  -- ---------- Setup: Owner (tg 7101) + Partnerin (tg 7102) + Kind ohne Telegram ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'progress_event fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__pe_owner__','first_name','PE','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7101,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__pe_partner__','first_name','PE','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7102,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__pe_kid__','first_name','PE','last_name','Kid',
                               'role','child','birth_date','2015-01-01','as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  INSERT INTO core.package_registry (package, version, status) VALUES ('core','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status = 'active';
  -- nur core + finance aktiv (die anderen Pakete fallen aus der Uebersicht)
  UPDATE core.package_registry SET status = 'inactive' WHERE package NOT IN ('core', 'finance');
  DELETE FROM finance.onboarding_state;
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('__pe_fin__', 1, 'PE Fin');
  UPDATE agent.guide_onboarding_state SET status = 'unknown' WHERE section_key = 'household';
  DELETE FROM core.notification_state WHERE source = 'onboarding';
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'learn_context';

  -- ---------- 1) Haushalt fertig (finance noch offen) -> member_chats = [7102], kein all_done ----------
  UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE section_key = 'household';
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"core","area_completed_now":true}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 ok]: %', r; END IF;
  IF r->'member_chats' <> '[7102]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [1 Haushalt fertig -> member_chats=[7102] (Kind ohne Telegram nie)]: %', r; END IF;
  IF (r->>'send_all_done')::boolean IS NOT FALSE OR (r->>'send_learn_offer')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1 finance offen -> kein all_done/learn]: %', r; END IF;

  -- ---------- 2) dasselbe Ereignis nochmal -> member_chats leer (household_ready latcht einmal) ----------
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"core","area_completed_now":true}');
  IF jsonb_array_length(r->'member_chats') <> 0 THEN
    RAISE EXCEPTION 'FAIL [2 zweites Haushalt-Ereignis -> keine Mitglieder-Nachricht]: %', r; END IF;

  -- ---------- 3) Haushalt zuruecksetzen + wieder fertig -> trotzdem nicht nochmal (kein Re-Arm) ----------
  UPDATE agent.guide_onboarding_state SET status = 'unknown' WHERE section_key = 'household';
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"core","area_completed_now":false}');
  UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE section_key = 'household';
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"core","area_completed_now":true}');
  IF jsonb_array_length(r->'member_chats') <> 0 THEN
    RAISE EXCEPTION 'FAIL [3 Haushalt erneut fertig -> "Es kann losgehen" nur einmal ueberhaupt]: %', r; END IF;

  -- ---------- 4) letzter Bereich fertig (finance) -> all_done + learn_offer (Owner, learn aus) ----------
  UPDATE finance.onboarding_state SET status = 'completed';
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"finance","area_completed_now":true}');
  IF (r->>'send_all_done')::boolean IS NOT TRUE OR (r->>'send_learn_offer')::boolean IS NOT TRUE
     OR (r->>'all_complete')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [4 alles fertig -> send_all_done + send_learn_offer]: %', r; END IF;
  IF jsonb_array_length(r->'member_chats') <> 0 THEN
    RAISE EXCEPTION 'FAIL [4 finance-Ereignis -> keine Mitglieder-Nachricht]: %', r; END IF;

  -- ---------- 5) zweites Mal (z. B. paralleles Paket) -> nichts mehr ----------
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"finance","area_completed_now":true}');
  IF (r->>'send_all_done')::boolean IS NOT FALSE OR (r->>'send_learn_offer')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [5 all_done nur einmal]: %', r; END IF;

  -- ---------- 6) neues Paket-Abschnitt offen (Re-Arm), wieder fertig -> all_done erneut; learn schon an -> nein ----------
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('__pe_fin2__', 2, 'PE Fin 2');
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"finance","area_completed_now":false}');
  IF (r->>'all_complete')::boolean IS NOT FALSE OR (r->>'send_all_done')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [6a offen -> all_complete=false, nichts senden]: %', r; END IF;
  UPDATE finance.onboarding_state SET status = 'skipped' WHERE section_key = '__pe_fin2__';
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'learn_context';
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"finance","area_completed_now":true}');
  IF (r->>'send_all_done')::boolean IS NOT TRUE OR (r->>'send_learn_offer')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [6b re-armed all_done ja, learn schon an -> kein Angebot]: %', r; END IF;

  -- ---------- 6c) Review-Fund: neues Paket oeffnet EINEN Bereich, der direkt wieder geschlossen wird, ohne dass je
  --            ein Aufruf mit offenem Stand kam -> trotzdem erneut "alles eingerichtet" (Abschnitt juenger als Latch) ----------
  UPDATE core.notification_state SET last_fired_at = now() - interval '1 hour'
   WHERE source = 'onboarding' AND key = 'all_done:__pe_owner__';
  INSERT INTO finance.onboarding_state (section_key, ord, label, status, status_changed_at)
    VALUES ('__pe_fin3__', 3, 'PE Fin 3', 'completed', now());
  r := core.fn_onboarding_progress_event('{"chat_id":"7101","package":"finance","area_completed_now":true}');
  IF (r->>'send_all_done')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [6c neuer Bereich nach Latch fertig -> all_done erneut]: %', r; END IF;

  -- ---------- 7) Mitglied (keine per_user-Pakete aktiv) -> nie all_done/learn ----------
  r := core.fn_onboarding_progress_event('{"chat_id":"7102","package":"finance","area_completed_now":true}');
  IF (r->>'send_all_done')::boolean IS NOT FALSE OR (r->>'send_learn_offer')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [7 Mitglied ohne eigene Bereiche -> nichts]: %', r; END IF;

  -- ---------- 8) unaufgeloester Sender -> ok, nichts ----------
  r := core.fn_onboarding_progress_event('{"chat_id":"999999","package":"finance","area_completed_now":true}');
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'send_all_done')::boolean IS NOT FALSE
     OR jsonb_array_length(r->'member_chats') <> 0 THEN
    RAISE EXCEPTION 'FAIL [8 unaufgeloest -> ok, nichts]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_onboarding_progress_event (all_done/learn/household_ready je genau einmal)';
END $$;

ROLLBACK;
