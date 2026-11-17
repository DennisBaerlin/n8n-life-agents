-- tests/db/core/test_fn_update_requests.sql
-- Update-Hinweis: Auftrags-Bruecke n8n -> root-Runner + Fehler-Hilfe.
--   core.fn_handle_update_cb(p)       = Registry-Handler 'upd' (owner-only): upd:now|retry:<tag> -> Auftrag + Toast.
--   core.fn_update_retry_allowed(tag) = eine Regel fuer [Erneut versuchen] (Handler + Hilfe-Knopf).
--   core.fn_update_request_claim(p)   = Runner (unter der Sperre): Haengende schliessen, offenen Auftrag uebernehmen.
--   core.fn_update_request_finish(p)  = Runner: Ergebnis festhalten (nie RAISE).
--   core.fn_update_report(p)          = Text + Knoepfe jeder Runner-Meldung (Fehlerklassen -> Hilfe), Owner-Sprache.
-- db_test hat kein seed_data -> family + Registry-Zeile self-seeden; Texte fallen auf den Key zurueck. BEGIN..ROLLBACK.
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
  -- Wiederholung nach partial: VERSION war schon beim Start = Tag -> ein Abbruch ist nicht "fertig"
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
  IF position('github.com/owner/repo/security/advisories/new' IN v_kb) = 0 OR position('GEHEIM' IN v_kb) > 0 THEN RAISE EXCEPTION 'FAIL [8c Problem melden ohne Detail]: %', v_kb; END IF;
  IF position('issues/new' IN v_kb) > 0 THEN RAISE EXCEPTION 'FAIL [8c Issues sind aus]: %', v_kb; END IF;
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
  IF position('github.com/owner/repo' IN v_kb) > 0 THEN RAISE EXCEPTION 'FAIL [8d Problem melden nur bei security]: %', v_kb; END IF;
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

  -- ---------- 9) Fortschritts-Plan: fertig gerenderte Texte je Schritt ----------
  DELETE FROM core.update_requests;
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.update.bar.filled', 'de', '#', 'core'), ('core.update.bar.empty', 'de', '-', 'core'),
    ('core.update.progress', 'de', 'P {tag} {bar} {pct} {stage}', 'core'),
    ('core.update.progress.done', 'de', 'D {tag} {bar} {pct}', 'core'),
    ('core.update.progress.stopped', 'de', 'S {tag} {bar} {pct}', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now(), 'v0.14.0') RETURNING id INTO v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'progress_plan'));
  IF r#>>'{start,pct}' IS DISTINCT FROM '0' OR position('P v0.15.0 ---------- 0' IN r#>>'{start,text}') = 0 THEN RAISE EXCEPTION 'FAIL [9a start]: %', r; END IF;
  IF r#>>'{done,text}' IS DISTINCT FROM 'D v0.15.0 ########## 100' THEN RAISE EXCEPTION 'FAIL [9b done]: %', r; END IF;
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r->'stages') k) IS DISTINCT FROM
     (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['download','verify','preflight','base','backup','postgres','n8n','gateway',
                                                       'schema','access','workflows','packages','cli','final']) k)
  THEN RAISE EXCEPTION 'FAIL [9c jeder Schritt-Code hat ein Gewicht]: %', r->'stages'; END IF;
  DECLARE
    v_prev int := 0; v_pct int; v_code text;
  BEGIN
    FOREACH v_code IN ARRAY ARRAY['download','verify','preflight','base','backup','postgres','n8n','gateway',
                                  'schema','access','workflows','packages','cli','final'] LOOP
      v_pct := (r->'stages'->v_code->>'pct')::int;
      IF v_pct <= v_prev OR v_pct >= 100 THEN RAISE EXCEPTION 'FAIL [9d % steigt nicht: % nach %]', v_code, v_pct, v_prev; END IF;
      v_prev := v_pct;
    END LOOP;
  END;
  v_txt := r#>'{stages,postgres}'->>'text';
  IF position('####------ 40 core.update.stage.postgres' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [9e Balken 40 %%]: %', v_txt; END IF;
  v_txt := r#>'{stages,n8n}'->>'text';
  IF position('####------ 45' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [9f Balken rundet ab]: %', v_txt; END IF;
  IF r#>'{stages,n8n}'->>'stopped' IS DISTINCT FROM 'S v0.15.0 ####------ 45' THEN RAISE EXCEPTION 'FAIL [9g gestoppt]: %', r#>'{stages,n8n}'; END IF;
  -- unbekannter Auftrag -> kein Plan, kein RAISE
  r := core.fn_update_report('{"request_id":-1,"phase":"progress_plan"}');
  IF r ? 'stages' THEN RAISE EXCEPTION 'FAIL [9h unbekannt]: %', r; END IF;

  -- ---------- 10) Erfolg, aber Bot antwortet nicht -> kein „alles laeuft“ ----------
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome) VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'succeeded') RETURNING id INTO v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false, 'help_url', 'https://example.org/hilfe'));
  IF r->>'class' IS DISTINCT FROM 'done_not_ready' OR position('core.update.done_not_ready' IN r->>'text') = 0 THEN RAISE EXCEPTION 'FAIL [10a Klasse]: %', r; END IF;
  IF r->'keyboard' <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [10b keine Knoepfe]: %', r; END IF;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true));
  IF r->>'class' IS DISTINCT FROM 'done' THEN RAISE EXCEPTION 'FAIL [10c mit Bot -> done]: %', r; END IF;

  -- ---------- 11) Merker: faellig -> gesendet ----------
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now(), 'v0.14.0') RETURNING id INTO v_id;
  -- ohne report-Key (alter Runner) bleibt die Zeile aussen vor: er meldet selbst
  PERFORM core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'failed', 'stage', 'download', 'reason_code', 'net', 'changed', false));
  IF (SELECT report_state FROM core.update_requests WHERE id = v_id) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [11a alter Runner -> NULL]'; END IF;
  r := core.fn_update_report_due('{}');
  IF jsonb_array_length(r) <> 0 THEN RAISE EXCEPTION 'FAIL [11b Altbestand nie nachsenden]: %', r; END IF;
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now(), 'v0.14.0') RETURNING id INTO v_id;
  PERFORM core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'failed', 'stage', 'workflows', 'reason_code', 'unknown', 'changed', true,
            'report', jsonb_build_object('log', '/var/log/x.log', 'backup', '/var/backups/x.gpg')));
  r := core.fn_update_report_due('{"bot_up":false}');
  IF jsonb_array_length(r) <> 1 OR (r#>>'{0,id}')::bigint IS DISTINCT FROM v_id OR r#>>'{0,params,log}' IS DISTINCT FROM '/var/log/x.log' THEN RAISE EXCEPTION 'FAIL [11c faellig mit Parametern]: %', r; END IF;
  r := core.fn_update_report_sent(jsonb_build_object('id', v_id));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [11d sent]: %', r; END IF;
  IF jsonb_array_length(core.fn_update_report_due('{}')) <> 0 THEN RAISE EXCEPTION 'FAIL [11e nach sent nichts mehr]'; END IF;
  r := core.fn_update_report_sent(jsonb_build_object('id', v_id));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'changed')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [11f zweimal harmlos]: %', r; END IF;
  r := core.fn_update_report_sent('{"id":"kaputt"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [11g ungueltig, kein RAISE]: %', r; END IF;

  -- 24-Stunden-Grenze
  UPDATE core.update_requests SET report_state = 'due', finished_at = now() - interval '25 hours' WHERE id = v_id;
  IF jsonb_array_length(core.fn_update_report_due('{}')) <> 0 THEN RAISE EXCEPTION 'FAIL [11h nach 24 h nicht mehr]'; END IF;

  -- Erfolg/teilweise warten auf den Bot, hoechstens 15 Minuten; Fehler und "schon aktuell" nie
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, report_state) VALUES
    ('v0.15.0', now(), 'v0.14.0', now(), 'succeeded', 'due') RETURNING id INTO v_id;
  IF jsonb_array_length(core.fn_update_report_due('{"bot_up":false}')) <> 0 THEN RAISE EXCEPTION 'FAIL [11i Erfolg wartet auf Bot]'; END IF;
  IF jsonb_array_length(core.fn_update_report_due('{"bot_up":true}')) <> 1 THEN RAISE EXCEPTION 'FAIL [11j Bot bereit -> faellig]'; END IF;
  IF jsonb_array_length(core.fn_update_report_due('{}')) <> 1 THEN RAISE EXCEPTION 'FAIL [11k ohne bot_up: alles Offene zaehlen]'; END IF;
  UPDATE core.update_requests SET finished_at = now() - interval '16 minutes', outcome = 'partial' WHERE id = v_id;
  IF jsonb_array_length(core.fn_update_report_due('{"bot_up":false}')) <> 1 THEN RAISE EXCEPTION 'FAIL [11l nach 15 min auch ohne Bot]'; END IF;
  UPDATE core.update_requests SET finished_at = now(), outcome = 'already_current' WHERE id = v_id;
  IF jsonb_array_length(core.fn_update_report_due('{"bot_up":false}')) <> 1 THEN RAISE EXCEPTION 'FAIL [11m ohne Wartepflicht]'; END IF;

  -- ---------- 12) Claim markiert erholte Auftraege nur mit report:true ----------
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now(), 'v0.14.0') RETURNING id INTO v_id;
  PERFORM core.fn_update_request_claim('{"installed":"v0.14.0"}');
  IF (SELECT report_state FROM core.update_requests WHERE id = v_id) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [12a alter Runner meldet selbst]'; END IF;
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now(), 'v0.14.0') RETURNING id INTO v_id;
  PERFORM core.fn_update_request_claim('{"installed":"v0.14.0","report":true}');
  IF (SELECT report_state FROM core.update_requests WHERE id = v_id) IS DISTINCT FROM 'due' THEN RAISE EXCEPTION 'FAIL [12b erholt -> due]'; END IF;

  -- ---------- 13) Frist: ein uebernommener Auftrag, der laenger haengt als jeder Runner-Lauf, blockiert den Knopf nicht ----------
  -- Grenze = zwei Runner-Laeufe (alter + neuer master im Docker-Verbund, je 2 h) + Puffer: 4 h 30 min ab Uebernahme.
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.15.0', now() - interval '4 hours 20 minutes', 'v0.14.0')
    RETURNING id INTO v_id;
  r := core.fn_handle_update_cb('{"data":"upd:now:v0.15.0","chat_id":"8201"}');
  IF r->>'reason' IS DISTINCT FROM 'already_open' THEN RAISE EXCEPTION 'FAIL [13a innerhalb der Frist laeuft schon]: %', r; END IF;
  UPDATE core.update_requests SET claimed_at = now() - interval '4 hours 31 minutes' WHERE id = v_id;
  r := core.fn_handle_update_cb('{"data":"upd:now:v0.15.0","chat_id":"8201"}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [13b nach der Frist neuer Auftrag]: %', r; END IF;
  IF (SELECT outcome FROM core.update_requests WHERE id = v_id) IS DISTINCT FROM 'interrupted'
     OR (SELECT report_state FROM core.update_requests WHERE id = v_id) IS DISTINCT FROM 'due'
     OR (SELECT finished_at FROM core.update_requests WHERE id = v_id) IS NULL THEN
    RAISE EXCEPTION 'FAIL [13c alter Auftrag interrupted + Meldung faellig]: %', (SELECT row_to_json(u) FROM core.update_requests u WHERE id = v_id);
  END IF;
  SELECT count(*) INTO v_cnt FROM core.update_requests WHERE finished_at IS NULL;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [13d genau ein offener Auftrag, ist %]', v_cnt; END IF;
  -- Ein spaet endender Lauf trifft den geschlossenen Auftrag nicht mehr (kein RAISE, nichts ueberschrieben).
  r := core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'succeeded'));
  IF r->>'reason' IS DISTINCT FROM 'not_open' THEN RAISE EXCEPTION 'FAIL [13e spaetes finish]: %', r; END IF;
  -- Nie uebernommen (Runner laeuft nicht): bleibt offen, Frist gilt nur fuer uebernommene (finish_claimed ist Gesetz).
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, requested_at) VALUES ('v0.15.0', now() - interval '9 hours') RETURNING id INTO v_id;
  r := core.fn_handle_update_cb('{"data":"upd:now:v0.15.0","chat_id":"8201"}');
  IF r->>'reason' IS DISTINCT FROM 'already_open' THEN RAISE EXCEPTION 'FAIL [13f nie uebernommen bleibt offen]: %', r; END IF;
  -- Mitglied loest das Schliessen nicht aus (Owner-Gate vor der Frist).
  UPDATE core.update_requests SET claimed_at = now() - interval '5 hours' WHERE id = v_id;
  r := core.fn_handle_update_cb('{"data":"upd:now:v0.15.0","chat_id":"8202"}');
  IF (SELECT finished_at FROM core.update_requests WHERE id = v_id) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [13g Mitglied schliesst nicht]'; END IF;

  -- ---------- 14) Befehl je Weg: der Runner gibt cli/cli_tty mit (rt_cli_hint), die Hilfe nennt genau diesen Befehl ----------
  -- Klassisch `sudo lifeagents`, Verbund `docker exec -i|-it <projekt>-master lifeagents`; -it nur fuer Befehle mit Rueckfrage
  -- (rollback, reconfigure). Unbekanntes/fehlendes cli (alter Runner beim Umstieg) -> klassisch.
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.update.where.server', 'de', 'WS', 'core'), ('core.update.where.docker', 'de', 'WD', 'core'),
    ('core.update.todo.later', 'de', 'TL {where}|{cli} update', 'core'),
    ('core.update.todo.terminal_update', 'de', 'TU {where}|{cli} update', 'core'),
    ('core.update.todo.rollback', 'de', 'RB {where}|{cli_tty} rollback', 'core'),
    ('core.update.todo.held', 'de', 'TH {where}|{cli_tty} reconfigure', 'core'),
    ('core.update.todo.doctor', 'de', 'TD {where}|{cli} doctor', 'core'),
    ('core.update.done_not_ready', 'de', 'DNR {where}|{cli} doctor', 'core'),
    ('core.update.todo.disk', 'de', 'DISK', 'core'), ('core.update.todo.disk_docker', 'de', 'DISKDOCKER', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;
  DECLARE
    c_dk  constant text := 'docker exec -i la-x-master lifeagents';
    c_dkt constant text := 'docker exec -it la-x-master lifeagents';
    -- r14 <outcome> <reason> <changed> <from_version> <bot_up> <cli|null> <cli_tty|null> -> Text der Meldung
    v_t text;
  BEGIN
    -- 14a Docker, mittendrin, Bot aus: Terminal-Update mit -i, Rueckweg mit -it, Ort "Docker"
    DELETE FROM core.update_requests;
    INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed)
    VALUES ('v0.15.0', now(), 'v0.14.0', now(), 'failed', 'workflows', 'unknown', true) RETURNING id INTO v_id;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false,
             'cli', c_dk, 'cli_tty', c_dkt))->>'text';
    IF position('TU WD|' || c_dk || ' update' IN v_t) = 0 OR position('RB WD|' || c_dkt || ' rollback' IN v_t) = 0
       OR position('sudo' IN v_t) > 0 THEN RAISE EXCEPTION 'FAIL [14a Docker bot_down]: %', v_t; END IF;
    -- 14b gleicher Fall klassisch: sudo, Ort "Server", kein docker
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false,
             'cli', 'sudo lifeagents', 'cli_tty', 'sudo lifeagents'))->>'text';
    IF position('TU WS|sudo lifeagents update' IN v_t) = 0 OR position('RB WS|sudo lifeagents rollback' IN v_t) = 0
       OR position('docker' IN v_t) > 0 THEN RAISE EXCEPTION 'FAIL [14b klassisch bot_down]: %', v_t; END IF;
    -- 14c ohne cli (alter Runner) -> klassisch; fremdes cli (kein erlaubtes Muster) -> klassisch, nie der fremde Text
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false))->>'text';
    IF position('TU WS|sudo lifeagents update' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14c ohne cli]: %', v_t; END IF;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false,
             'cli', 'rm -rf / ; lifeagents', 'cli_tty', 'docker exec -it a b; lifeagents'))->>'text';
    IF position('rm -rf' IN v_t) > 0 OR position('a b;' IN v_t) > 0 OR position('TU WS|sudo lifeagents update' IN v_t) = 0
       OR position('RB WS|sudo lifeagents rollback' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14c fremdes cli]: %', v_t; END IF;
    -- 14d Rueckweg nur, wenn `lifeagents rollback` dort laufen kann (upgrade_rollback): klassisch nur mit Release-Tag,
    --     Verbund mit irgendeiner Versionsangabe (dev), ohne Angabe nirgends
    UPDATE core.update_requests SET from_version = 'dev' WHERE id = v_id;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false, 'cli', 'sudo lifeagents'))->>'text';
    IF position('RB ' IN v_t) > 0 OR position('TU WS|' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14d klassisch dev ohne Rueckweg]: %', v_t; END IF;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false, 'cli', c_dk, 'cli_tty', c_dkt))->>'text';
    IF position('RB WD|' || c_dkt IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14d Docker dev mit Rueckweg]: %', v_t; END IF;
    UPDATE core.update_requests SET from_version = NULL WHERE id = v_id;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false, 'cli', c_dk, 'cli_tty', c_dkt))->>'text';
    IF position('RB ' IN v_t) > 0 THEN RAISE EXCEPTION 'FAIL [14d Docker ohne Version ohne Rueckweg]: %', v_t; END IF;
    -- 14e nichts geaendert: spaeter (cli -i), Speicherplatz je Weg (Docker ohne df-Befehl); Bot aus -> kein Wiederholen-Knopf, also "spaeter"
    DELETE FROM core.update_requests;
    INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed)
    VALUES ('v0.16.0', now(), 'v0.15.0', now(), 'failed', 'preflight', 'disk', false) RETURNING id INTO v_id;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false, 'cli', c_dk, 'cli_tty', c_dkt))->>'text';
    IF position('DISKDOCKER' IN v_t) = 0 OR position('TL WD|' || c_dk || ' update' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14e Docker Platz]: %', v_t; END IF;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false, 'cli', 'sudo lifeagents'))->>'text';
    IF position('DISKDOCKER' IN v_t) > 0 OR position('DISK' IN v_t) = 0 OR position('TL WS|sudo lifeagents update' IN v_t) = 0
    THEN RAISE EXCEPTION 'FAIL [14e klassisch Platz]: %', v_t; END IF;
    -- 14f wartet (reconfigure mit -it), teilweise + fertig ohne Bot (doctor mit -i)
    DELETE FROM core.update_requests;
    INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, changed)
    VALUES ('v0.16.0', now(), 'v0.15.0', now(), 'held', false) RETURNING id INTO v_id;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'missing', 'X', 'cli', c_dk, 'cli_tty', c_dkt))->>'text';
    IF position('TH WD|' || c_dkt || ' reconfigure' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14f held Docker]: %', v_t; END IF;
    UPDATE core.update_requests SET outcome = 'partial', changed = true WHERE id = v_id;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'failed', 'Y', 'cli', c_dk, 'cli_tty', c_dkt))->>'text';
    IF position('TD WD|' || c_dk || ' doctor' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14f partial Docker]: %', v_t; END IF;
    UPDATE core.update_requests SET outcome = 'succeeded' WHERE id = v_id;
    v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', false, 'cli', 'sudo lifeagents'))->>'text';
    IF position('DNR WS|sudo lifeagents doctor' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [14f done_not_ready klassisch]: %', v_t; END IF;
  END;

  -- ---------- 15) Abbruch-Gruende ohne Sinn fuer eine Wiederholung: eigener Satz, kein Knopf, kein "spaeter" ----------
  -- master_image (Release ohne master-Image) und pg_major (Daten in anderer PostgreSQL-Hauptversion) kaemen beim selben Tag wieder.
  FOR v_txt IN SELECT unnest(ARRAY['master_image', 'pg_major']) LOOP
    DELETE FROM core.update_requests;
    INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed)
    VALUES ('v0.16.0', now(), 'v0.15.0', now(), 'failed', 'preflight', v_txt, false) RETURNING id INTO v_id;
    IF core.fn_update_retry_allowed('v0.16.0') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [15a % -> kein retry]', v_txt; END IF;
    r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true,
           'help_url', 'https://example.org/hilfe', 'cli', 'sudo lifeagents'));
    IF position('core.update.reason.' || v_txt IN r->>'text') = 0 OR position('core.update.reason.unknown' IN r->>'text') > 0
    THEN RAISE EXCEPTION 'FAIL [15b % eigener Satz]: %', v_txt, r->>'text'; END IF;
    IF position('core.update.todo.no_retry' IN r->>'text') = 0 OR position('TL ' IN r->>'text') > 0
       OR position('core.update.todo.retry' IN r->>'text') > 0 THEN RAISE EXCEPTION 'FAIL [15c % Folgezeile]: %', v_txt, r->>'text'; END IF;
    IF position('callback_data' IN r->>'keyboard') > 0 OR position('https://example.org/hilfe#unchanged' IN r->>'keyboard') = 0
    THEN RAISE EXCEPTION 'FAIL [15d % Knoepfe]: %', v_txt, r->'keyboard'; END IF;
  END LOOP;
  -- pg_major aus upgrade_detect kommt nach `result_set changed true` (Schritt base), aber vor jedem Tausch -> trotzdem
  -- "nichts geaendert" mit Grund, nie "mittendrin" (dessen Kopf nennt keinen Grund) und kein Rueckweg.
  UPDATE core.update_requests SET changed = true, stage = 'base' WHERE id = v_id;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'cli', 'docker exec -i la-x-master lifeagents'));
  IF r->>'class' IS DISTINCT FROM 'unchanged' OR position('core.update.reason.pg_major' IN r->>'text') = 0
     OR position('RB ' IN r->>'text') > 0 THEN RAISE EXCEPTION 'FAIL [15e pg_major nach changed=true]: %', r; END IF;

  -- ---------- 16) "Laeuft weiter auf ...": Versionsangabe nur mit Release-Tag, nie "?" oder "dev" ----------
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.update.from_note', 'de', ' (V {from})', 'core'),
    ('core.update.held', 'de', 'HELD{from_note}.', 'core'),
    ('core.update.fail.unchanged', 'de', 'UNCH{from_note}.', 'core'),
    ('core.update.fail.security', 'de', 'SEC{from_note}.', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;
  DECLARE
    v_t text; v_case text[];
  BEGIN
    FOREACH v_case SLICE 1 IN ARRAY ARRAY[['held', '', 'HELD'], ['failed', 'net', 'UNCH'], ['failed', 'signature', 'SEC']] LOOP
      DELETE FROM core.update_requests;
      INSERT INTO core.update_requests (tag, claimed_at, from_version, finished_at, outcome, stage, reason_code, changed)
      VALUES ('v0.16.0', now(), 'v0.15.0', now(), v_case[1], 'download', NULLIF(v_case[2], ''), false) RETURNING id INTO v_id;
      v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'missing', 'X'))->>'text';
      IF position(v_case[3] || ' (V v0.15.0).' IN v_t) = 0 THEN RAISE EXCEPTION 'FAIL [16a % mit Version]: %', v_case[3], v_t; END IF;
      UPDATE core.update_requests SET from_version = NULL WHERE id = v_id;
      v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'missing', 'X'))->>'text';
      IF position(v_case[3] || '.' IN v_t) = 0 OR position('?' IN v_t) > 0 THEN RAISE EXCEPTION 'FAIL [16b % ohne Version]: %', v_case[3], v_t; END IF;
      UPDATE core.update_requests SET from_version = 'dev' WHERE id = v_id;
      v_t := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'missing', 'X'))->>'text';
      IF position(v_case[3] || '.' IN v_t) = 0 OR position('dev' IN v_t) > 0 THEN RAISE EXCEPTION 'FAIL [16c % dev]: %', v_case[3], v_t; END IF;
    END LOOP;
  END;

  -- ---------- 17) Codes mit Ziffer (Schritt "n8n", Grund "n8n_start"): gespeichert und im Bericht benannt ----------
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.16.0', now(), 'v0.15.0') RETURNING id INTO v_id;
  r := core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'failed', 'stage', 'n8n',
         'reason_code', 'n8n_start', 'changed', true));
  IF (SELECT stage FROM core.update_requests WHERE id = v_id) IS DISTINCT FROM 'n8n'
     OR (SELECT reason_code FROM core.update_requests WHERE id = v_id) IS DISTINCT FROM 'n8n_start'
  THEN RAISE EXCEPTION 'FAIL [17a Code mit Ziffer verworfen]: %', (SELECT row_to_json(u) FROM core.update_requests u WHERE id = v_id); END IF;
  r := core.fn_update_report(jsonb_build_object('request_id', v_id, 'phase', 'result', 'bot_up', true, 'cli', 'sudo lifeagents'));
  IF position(core.fn_ui_text('core.update.stage.unknown', 'de') IN r->>'text') > 0
     OR position(core.fn_ui_text('core.update.reason.unknown', 'de') IN r->>'text') > 0
  THEN RAISE EXCEPTION 'FAIL [17b Bericht nennt Schritt/Grund nicht]: %', r->>'text'; END IF;
  -- Die Form bleibt eng: Ziffer vorn, Grossbuchstabe, Leerzeichen -> NULL (finish) bzw. abgelehnt (CHECK)
  DELETE FROM core.update_requests;
  INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v0.16.0', now(), 'v0.15.0') RETURNING id INTO v_id;
  r := core.fn_update_request_finish(jsonb_build_object('id', v_id, 'outcome', 'failed', 'stage', '8n', 'reason_code', 'N8n start'));
  IF (SELECT stage IS NOT NULL OR reason_code IS NOT NULL FROM core.update_requests WHERE id = v_id)
  THEN RAISE EXCEPTION 'FAIL [17c ungueltige Form uebernommen]'; END IF;
  BEGIN
    UPDATE core.update_requests SET stage = 'X-1' WHERE id = v_id;
    RAISE EXCEPTION 'FAIL [17d CHECK nimmt X-1]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  RAISE NOTICE 'test_fn_update_requests: alle Faelle gruen';
END $$;

ROLLBACK;
