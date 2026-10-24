-- tests/db/core/test_fn_update_requests.sql
-- Update-Hinweis (2026-10-24): Auftrags-Bruecke n8n -> root-Runner + Fehler-Hilfe.
--   core.fn_handle_update_cb(p)       = Registry-Handler 'upd' (owner-only): upd:now|retry:<tag> -> Auftrag + Toast.
--   core.fn_update_retry_allowed(tag) = EINE Regel fuer [Erneut versuchen] (Handler + Hilfe-Knopf).
--   core.fn_update_request_claim(p)   = Runner (unter der Sperre): Haengende schliessen, offenen Auftrag uebernehmen.
--   core.fn_update_request_finish(p)  = Runner: Ergebnis festhalten (nie RAISE).
--   core.fn_update_report(p)          = Text + Knoepfe jeder Runner-Meldung (Fehlerklassen -> Hilfe), Owner-Sprache.
-- db_test hat KEIN seed_data -> family + Registry-Zeile self-seeden; Texte fallen auf den Key zurueck. BEGIN..ROLLBACK.
BEGIN;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'update_requests fixture', NULL, 'lazy', E'## fam',
        jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','ur_owner','first_name','UR','last_name','Owner',
                             'role','owner','birth_date','1980-01-01','telegram_user_id',8201,'language','de','as_of','2026-10-24'),
          jsonb_build_object('person_id','ur_partner','first_name','UR','last_name','Partner',
                             'role','partner','birth_date','1982-01-01','telegram_user_id',8202,'as_of','2026-10-24')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
VALUES ('upd', 'core.fn_handle_update_cb', 'core', FALSE)
ON CONFLICT (prefix) DO UPDATE SET handler_fn = excluded.handler_fn, member_permeable = excluded.member_permeable;

-- Katalog-Fixture: Kopf-Texte = Key + Platzhalter -> die Assertions sehen, dass Grund/Schritt eingesetzt werden
-- (deren Texte fallen ohne Seed auf den Key zurueck: core.update.reason.<code> / core.update.stage.<code>).
INSERT INTO core.ui_texts (key, lang, text, package)
SELECT k, 'de', k || ' {reason} {stage}', 'core'
FROM unnest(ARRAY['core.update.fail.unchanged', 'core.update.fail.security', 'core.update.fail.midway',
                  'core.update.fail.bot_down']) k
ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;

DELETE FROM core.update_requests;

DO $$
DECLARE
  r      jsonb;
  v_id   bigint;
  v_cnt  int;
  v_txt  text;
  v_kb   text;
BEGIN
  PERFORM core.fn_release_card_sent('v0.15.0');   -- die Karte fuer v0.15.0 wurde gesendet (Latch)

  -- ---------- 1) Owner tippt [Jetzt aktualisieren] -> Auftrag + Toast ----------
  r := core.fn_dispatch_callback('{"data":"upd:now:v0.15.0","chat_id":"8201","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'toast' IS NULL THEN RAISE EXCEPTION 'FAIL [1a ok + toast]: %', r; END IF;
  SELECT id INTO v_id FROM core.update_requests WHERE finished_at IS NULL AND tag = 'v0.15.0' AND kind = 'update' AND requested_by = 'ur_owner';
  IF v_id IS NULL THEN RAISE EXCEPTION 'FAIL [1b offene Zeile erwartet]'; END IF;

  -- ---------- 2) Doppel-Tap / Mitglied / ungueltig -> kein zweiter Auftrag ----------
  r := core.fn_dispatch_callback('{"data":"upd:now:v0.15.0","chat_id":"8201","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'already_open' THEN RAISE EXCEPTION 'FAIL [2a Doppel-Tap]: %', r; END IF;
  r := core.fn_dispatch_callback('{"data":"upd:now:v0.15.0","chat_id":"8202","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2b Mitglied abgelehnt]: %', r; END IF;
  r := core.fn_handle_update_cb('{"data":"upd:now:../etc","chat_id":"8201"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'invalid' THEN RAISE EXCEPTION 'FAIL [2c kaputter Tag]: %', r; END IF;
  r := core.fn_handle_update_cb('{"data":"upd:maybe:v0.15.0","chat_id":"8201"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'invalid' THEN RAISE EXCEPTION 'FAIL [2d Verb]: %', r; END IF;
  r := core.fn_handle_update_cb('{"data":"upd:now:v0.15.0","chat_id":"8202"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2e Handler direkt, Mitglied]: %', r; END IF;
  SELECT count(*) INTO v_cnt FROM core.update_requests;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [2f genau ein Auftrag, ist %]', v_cnt; END IF;

  -- ---------- 3) Constraint: zweiter offener Auftrag ist DB-Gesetz ----------
  BEGIN
    INSERT INTO core.update_requests (tag) VALUES ('v0.15.0');
    RAISE EXCEPTION 'FAIL [3 zweiter offener Auftrag muss scheitern]';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- ---------- 4) Claim + Recovery ----------
  r := core.fn_update_request_claim('{"installed":"v0.14.0"}');
  IF (r#>>'{claimed,id}')::bigint IS DISTINCT FROM v_id OR r#>>'{claimed,from_version}' IS DISTINCT FROM 'v0.14.0'
     OR jsonb_array_length(r->'recovered') <> 0 THEN RAISE EXCEPTION 'FAIL [4a claim]: %', r; END IF;
  -- Runner stirbt; naechster Lauf (unter der Sperre) -> Haengender wird interrupted (VERSION noch alt)
  r := core.fn_update_request_claim('{"installed":"v0.14.0"}');
  IF r->'claimed' <> 'null'::jsonb OR r#>>'{recovered,0,outcome}' IS DISTINCT FROM 'interrupted' THEN RAISE EXCEPTION 'FAIL [4b recovery interrupted]: %', r; END IF;
  -- gleicher Fall, aber VERSION = Tag (Abbruch nach dem CLI-Tausch) -> succeeded
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now(), 'v0.14.0');
  r := core.fn_update_request_claim('{"installed":"v0.15.0"}');
  IF r#>>'{recovered,0,outcome}' IS DISTINCT FROM 'succeeded' THEN RAISE EXCEPTION 'FAIL [4c recovery succeeded]: %', r; END IF;
  -- Wiederholung nach partial: VERSION war schon beim Start = Tag -> ein Abbruch ist NICHT "fertig" (Code-Review)
  INSERT INTO core.update_requests (kind, tag, claimed_at, from_version) VALUES ('retry', 'v0.15.0', now(), 'v0.15.0');
  r := core.fn_update_request_claim('{"installed":"v0.15.0"}');
  IF r#>>'{recovered,0,outcome}' IS DISTINCT FROM 'interrupted' THEN RAISE EXCEPTION 'FAIL [4d retry-Abbruch -> interrupted]: %', r; END IF;
  -- sehr lange (aber SemVer-gueltige) Tags: Handler raised nie, Tabelle nimmt dieselbe Form wie fn_semver_cmp
  DELETE FROM core.update_requests;
  PERFORM core.fn_release_card_sent('v123456.0.0');
  r := core.fn_handle_update_cb('{"data":"upd:now:v123456.0.0","chat_id":"8201"}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4e langes Tag angenommen, kein RAISE]: %', r; END IF;
  r := core.fn_handle_update_cb('{"data":"upd:now:v1234567.0.0","chat_id":"8201"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'invalid' THEN RAISE EXCEPTION 'FAIL [4f zu langes Tag -> invalid]: %', r; END IF;
  DELETE FROM core.update_requests;

  -- ---------- 5) Finish ----------
  DELETE FROM core.update_requests;
  r := core.fn_dispatch_callback('{"data":"upd:now:v0.15.0","chat_id":"8201","chat_type":"private"}');
  r := core.fn_update_request_claim('{"installed":"v0.14.0"}');
  v_id := (r#>>'{claimed,id}')::bigint;
  r := core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'bogus'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'invalid_outcome' THEN RAISE EXCEPTION 'FAIL [5a outcome]: %', r; END IF;
  r := core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'failed', 'stage', 'download',
         'reason_code', 'net', 'changed', false, 'detail', repeat('x', 900)));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5b finish]: %', r; END IF;
  IF (SELECT length(detail) FROM core.update_requests WHERE id = v_id) > 500 THEN RAISE EXCEPTION 'FAIL [5c detail gekuerzt]'; END IF;
  r := core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'succeeded'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'not_open' THEN RAISE EXCEPTION 'FAIL [5d zweimal]: %', r; END IF;

  -- ---------- 6) Erneut versuchen: max. 2 Wiederholungen ----------
  IF core.fn_update_retry_allowed('v0.15.0') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [6a retry nach net erlaubt]'; END IF;
  FOR i IN 1..2 LOOP
    r := core.fn_dispatch_callback('{"data":"upd:retry:v0.15.0","chat_id":"8201","chat_type":"private"}');
    IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [6b retry % angenommen]: %', i, r; END IF;
    r := core.fn_update_request_claim('{"installed":"v0.14.0"}');
    IF r#>>'{claimed,kind}' IS DISTINCT FROM 'retry' THEN RAISE EXCEPTION 'FAIL [6c kind retry]: %', r; END IF;
    PERFORM core.fn_update_request_finish(jsonb_build_object('id', (r#>>'{claimed,id}')::bigint, 'outcome', 'failed',
              'stage', 'workflows', 'reason_code', 'unknown', 'changed', true));
  END LOOP;
  IF core.fn_update_retry_allowed('v0.15.0') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6d nach 2 Wiederholungen aus]'; END IF;
  r := core.fn_dispatch_callback('{"data":"upd:retry:v0.15.0","chat_id":"8201","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'no_retry' THEN RAISE EXCEPTION 'FAIL [6e no_retry]: %', r; END IF;
  -- [Jetzt aktualisieren] bleibt moeglich (neuer Anlauf, zaehlt nicht als Wiederholung)
  IF core.fn_update_retry_allowed('v0.16.0') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6f ohne Vorlauf kein retry]'; END IF;

  -- ---------- 7) Sicherheitswarnung: nie wiederholen ----------
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed)
  VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'failed', 'verify', 'signature', false);
  IF core.fn_update_retry_allowed('v0.15.0') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7a signature -> kein retry]'; END IF;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome)
  VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'succeeded');
  IF core.fn_update_retry_allowed('v0.15.0') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7b nach succeeded kein retry]'; END IF;

  -- ---------- 8) Hilfe je Fehlerklasse ----------
  DELETE FROM core.update_requests;
  -- 8a Start-Meldung
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now(), 'v0.14.0') RETURNING id INTO v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'start'));
  IF position('core.update.running' IN r->>'text') = 0 THEN RAISE EXCEPTION 'FAIL [8a start]: %', r; END IF;
  -- 8b nichts geaendert (Netz) -> Ursache + [Erneut versuchen] + Hilfe-Link
  PERFORM core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'failed', 'stage', 'download', 'reason_code', 'net', 'changed', false));
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true,
         'help_url', 'https://example.org/hilfe', 'repo_slug', 'owner/repo'));
  v_txt := r->>'text'; v_kb := r->>'keyboard';
  IF position('core.update.fail.unchanged' IN v_txt) = 0 OR position('core.update.reason.net' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [8b Klasse]: %', v_txt; END IF;
  IF position('upd:retry:v0.15.0' IN v_kb) = 0 OR position('https://example.org/hilfe#' IN v_kb) = 0 THEN RAISE EXCEPTION 'FAIL [8b Knoepfe]: %', v_kb; END IF;
  -- 8c Sicherheitswarnung -> kein Wiederholen, dafuer [Problem melden] ohne Freitext
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed, detail)
  VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'failed', 'verify', 'signature', false, 'GEHEIM-host.example.lan') RETURNING id INTO v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true,
         'help_url', 'https://example.org/hilfe', 'repo_slug', 'owner/repo'));
  v_txt := r->>'text'; v_kb := r->>'keyboard';
  IF position('core.update.fail.security' IN v_txt) = 0 OR position('core.update.todo.security' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [8c Klasse]: %', v_txt; END IF;
  IF position('callback_data' IN v_kb) > 0 THEN RAISE EXCEPTION 'FAIL [8c kein Callback-Knopf]: %', v_kb; END IF;
  IF position('github.com/owner/repo/issues/new' IN v_kb) = 0 OR position('GEHEIM' IN v_kb) > 0 THEN RAISE EXCEPTION 'FAIL [8c Problem melden ohne Detail]: %', v_kb; END IF;
  -- 8d mittendrin abgebrochen, Bot laeuft -> [Erneut versuchen] + Rueckweg
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed)
  VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'failed', 'workflows', 'unknown', true) RETURNING id INTO v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true,
         'help_url', 'https://example.org/hilfe', 'repo_slug', 'owner/repo', 'backup', '/var/backups/lifeagents/x.dump.gpg'));
  v_txt := r->>'text'; v_kb := r->>'keyboard';
  IF position('core.update.fail.midway' IN v_txt) = 0 OR position('core.update.todo.rollback' IN v_txt) = 0
     OR position('core.update.stage.workflows' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [8d Klasse]: %', v_txt; END IF;
  IF position('upd:retry:v0.15.0' IN v_kb) = 0 THEN RAISE EXCEPTION 'FAIL [8d retry-Knopf]: %', v_kb; END IF;
  -- 8e gleicher Fall, Bot aus -> keine Callback-Knoepfe, Terminal-Schritte
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false,
         'help_url', 'https://example.org/hilfe', 'repo_slug', 'owner/repo'));
  v_txt := r->>'text'; v_kb := r->>'keyboard';
  IF position('core.update.fail.bot_down' IN v_txt) = 0 OR position('core.update.todo.terminal_update' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [8e Klasse]: %', v_txt; END IF;
  IF position('callback_data' IN v_kb) > 0 THEN RAISE EXCEPTION 'FAIL [8e keine Callback-Knoepfe]: %', v_kb; END IF;
  -- 8f teilweise / wartet / schon aktuell / ueberholt / fertig / unterbrochen
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed)
  VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'partial', 'packages', 'package', true) RETURNING id INTO v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'failed', 'Finanzen'));
  IF position('core.update.partial' IN r->>'text') = 0 OR position('upd:retry:v0.15.0' IN r->>'keyboard') = 0 THEN RAISE EXCEPTION 'FAIL [8f partial]: %', r; END IF;
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, changed)
  VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'held', false) RETURNING id INTO v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'missing', 'Telegram-Bot-Token'));
  IF position('core.update.held' IN r->>'text') = 0 OR position('core.update.todo.held' IN r->>'text') = 0 THEN RAISE EXCEPTION 'FAIL [8g held]: %', r; END IF;
  FOR v_txt IN SELECT unnest(ARRAY['already_current', 'superseded', 'succeeded', 'interrupted']) LOOP
    DELETE FROM core.update_requests;
    INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome)
    VALUES ('v0.15.0', now(), 'v0.14.0', now(), v_txt) RETURNING id INTO v_id;
    r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'latest', 'v0.16.0'));
    IF r->>'text' IS NULL OR length(r->>'text') = 0 OR jsonb_typeof(r->'keyboard') <> 'array' THEN RAISE EXCEPTION 'FAIL [8h %]: %', v_txt, r; END IF;
  END LOOP;
  IF position('core.update.fail.interrupted' IN r->>'text') = 0 THEN RAISE EXCEPTION 'FAIL [8i interrupted-Key]: %', r; END IF;
  -- 8j unbekannte Zeile -> kein RAISE, leerer Text
  r := core.fn_update_report('{"request_id":-1,"phase":"result"}');
  IF COALESCE(r->>'text', '') <> '' THEN RAISE EXCEPTION 'FAIL [8j unbekannt]: %', r; END IF;

  RAISE NOTICE 'test_fn_update_requests: alle Faelle gruen';
END $$;

ROLLBACK;
