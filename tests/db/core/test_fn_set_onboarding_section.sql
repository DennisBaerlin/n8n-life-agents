-- tests/db/core/test_fn_set_onboarding_section.sql
-- core.fn_set_onboarding_section: Haushalts-Sektionen (core/household-Pakete, kein per_user-Scope) setzt nur der
-- Owner. Ein positiv aufgeloestes Mitglied bekommt {ok:false, reason:'owner_only'} OHNE Write — sonst koennte es
-- z. B. den Haushalt auf 'unknown' zuruecksetzen und damit per Core-first-Gate alle Paket-Agenten fuer den
-- ganzen Haushalt sperren. Pruefung ueber das publizierte Fenster core.fn_check_write_permission('owner_only')
-- (Pass-Through bei fehlender/nicht-numerischer chat_id = CLI/Test/Sentinel, wie alle owner_only-fns).
-- per_user-Pakete (career) bleiben pro Person (eigene Zeile, eigener Test test_career_onboarding_person_scoping).
-- Rollen-Perspektive (finance_rw/estate_rw) zusaetzlich in tests/db/cross/test_role_permissions.sql (6).
-- db_test hat KEIN seed_data -> family + finance-Sektion self-seeden. BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE r JSONB; v_status text;
BEGIN
  -- ---------- Setup: family mit Owner (tg 6601) + Partnerin (tg 6602); eine finance-Sektion ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'set_onboarding_section fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__sos_owner__','first_name','SO','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',6601,'as_of','2026-10-21'),
            jsonb_build_object('person_id','__sos_partner__','first_name','SO','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',6602,'as_of','2026-10-21')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('__sos_sec__', 999, 'SOS Fixture')
  ON CONFLICT (section_key) DO NOTHING;
  UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE section_key = 'household';
  UPDATE finance.onboarding_state SET status = 'completed' WHERE section_key = '__sos_sec__';

  -- ---------- 1) Mitglied setzt den Haushalt zurueck -> owner_only, kein Write ----------
  r := core.fn_set_onboarding_section('{"package":"core","section_key":"household","status":"unknown","chat_id":"6602"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [Mitglied core/household -> owner_only erwartet]: %', r; END IF;
  SELECT status INTO v_status FROM agent.guide_onboarding_state WHERE section_key = 'household';
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'FAIL [Mitglied hat household trotzdem geschrieben: %]', v_status; END IF;

  -- ---------- 2) Mitglied markiert eine household-Paket-Sektion (finance) -> owner_only, kein Write ----------
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__sos_sec__","status":"skipped","chat_id":"6602"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [Mitglied finance -> owner_only erwartet]: %', r; END IF;
  SELECT status INTO v_status FROM finance.onboarding_state WHERE section_key = '__sos_sec__';
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'FAIL [Mitglied hat finance trotzdem geschrieben: %]', v_status; END IF;

  -- ---------- 3) Owner darf beides ----------
  r := core.fn_set_onboarding_section('{"package":"core","section_key":"household","status":"unknown","chat_id":"6601"}');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [Owner core/household]: %', r; END IF;
  SELECT status INTO v_status FROM agent.guide_onboarding_state WHERE section_key = 'household';
  IF v_status <> 'unknown' THEN RAISE EXCEPTION 'FAIL [Owner-Write kam nicht an: %]', v_status; END IF;
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__sos_sec__","status":"skipped","chat_id":"6601"}');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [Owner finance]: %', r; END IF;

  -- ---------- 4) ohne chat_id (CLI/Host) -> Pass-Through wie bisher ----------
  r := core.fn_set_onboarding_section('{"package":"core","section_key":"household","status":"completed"}');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [ohne chat_id muss durchgehen]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_set_onboarding_section (owner_only fuer Haushalts-Sektionen, Owner + Pass-Through ok)';
END $$;

-- ---------- Roter Faden: area_completed_now / area_all_skipped / status_changed_at ----------
-- Der Bereich (hier finance mit genau ZWEI Fixture-Sektionen) kippt von offen -> aufgeloest genau EINMAL;
-- erneutes Markieren eines schon aufgeloesten Bereichs liefert false (keine zweite Weiter-Karte).
-- status_changed_at bewegt sich nur bei echter Status-Aenderung (Label-Resync/Gleich-Status nicht).
DO $$
DECLARE r JSONB; v_ts timestamptz; v_ts2 timestamptz;
BEGIN
  DELETE FROM finance.onboarding_state;
  INSERT INTO finance.onboarding_state (section_key, ord, label, status, status_changed_at) VALUES
    ('__rf_a__', 1, 'RF A', 'unknown', now() - interval '5 days'),
    ('__rf_b__', 2, 'RF B', 'unknown', now() - interval '5 days');

  -- 1) erste Sektion fertig -> Bereich noch offen
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__rf_a__","status":"completed"}');
  IF (r->>'area_completed_now')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [1 Sektion offen -> area_completed_now=false erwartet]: %', r; END IF;
  SELECT status_changed_at INTO v_ts FROM finance.onboarding_state WHERE section_key = '__rf_a__';
  IF v_ts < now() - interval '1 minute' THEN
    RAISE EXCEPTION 'FAIL [status_changed_at nicht gesetzt bei Status-Wechsel: %]', v_ts; END IF;

  -- 2) zweite Sektion fertig -> Bereich kippt JETZT
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__rf_b__","status":"completed"}');
  IF (r->>'area_completed_now')::boolean IS NOT TRUE OR (r->>'area_all_skipped')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [Bereich fertig -> area_completed_now=true, area_all_skipped=false erwartet]: %', r; END IF;

  -- 3) dieselbe Sektion nochmal completed -> kein zweiter Kipp; status_changed_at unveraendert
  UPDATE finance.onboarding_state SET status_changed_at = now() - interval '2 days' WHERE section_key = '__rf_b__';
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__rf_b__","status":"completed"}');
  IF (r->>'area_completed_now')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [erneutes Markieren -> area_completed_now=false erwartet]: %', r; END IF;
  SELECT status_changed_at INTO v_ts2 FROM finance.onboarding_state WHERE section_key = '__rf_b__';
  IF v_ts2 > now() - interval '1 day' THEN
    RAISE EXCEPTION 'FAIL [gleicher Status darf status_changed_at nicht bewegen: %]', v_ts2; END IF;

  -- 4) completed -> skipped (Bereich bleibt aufgeloest) -> kein Kipp
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__rf_b__","status":"skipped"}');
  IF (r->>'area_completed_now')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [completed->skipped -> area_completed_now=false erwartet]: %', r; END IF;

  -- 5) wieder oeffnen und nur ueberspringen -> Kipp mit area_all_skipped=true
  UPDATE finance.onboarding_state SET status = 'unknown';
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__rf_a__","status":"skipped"}');
  IF (r->>'area_completed_now')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [eine von zwei uebersprungen -> noch offen]: %', r; END IF;
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__rf_b__","status":"skipped"}');
  IF (r->>'area_completed_now')::boolean IS NOT TRUE OR (r->>'area_all_skipped')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [nur uebersprungen -> area_completed_now=true + area_all_skipped=true erwartet]: %', r; END IF;

  -- 6) unknown setzen -> kein Kipp (Bereich wird offen)
  r := core.fn_set_onboarding_section('{"package":"finance","section_key":"__rf_a__","status":"unknown"}');
  IF (r->>'area_completed_now')::boolean IS NOT FALSE OR (r->>'complete')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [unknown -> offen, kein Kipp]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_set_onboarding_section (area_completed_now genau einmal je Uebergang, status_changed_at)';
END $$;

ROLLBACK;
