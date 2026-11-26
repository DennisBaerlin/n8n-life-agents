-- tests/db/core/test_fn_llm_probe_due.sql
-- core.fn_llm_probe_due(p) + core.fn_llm_probe_result(p) — Nachschau waehrend einer KI-Pause: faellig nach Plan
--   (ohne Wahl 10/30/60 Min, raise 10, wait ab resume_at + 1 Min, Stoerung 2/5/10), eine Nachschau zur Zeit (Sperre),
--   Ergebnis "noch gesperrt" (Cron still, Knopf mit Satz + Knopf), Erholung schliesst den Vorfall und liefert die
--   Nachrichten (Owner-Entwarnung bei Limit/Guthaben/Schluessel, je Person mit gemerkten Nachrichten Zitat/Anzahl/
--   Sprachnachricht + Knoepfe; Stoerung: nur Personen mit gemerkter Nachricht), Aufraeumen nach 7 Tagen. Alle Werte erfunden.
BEGIN;

SET LOCAL TimeZone = 'Europe/Berlin';

DO $$
DECLARE
  r jsonb; inc bigint; t0 timestamptz := now(); m jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'llm_probe fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__lp_owner__','first_name','LP','last_name','Owner','language','de',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7801,'as_of','2026-10-25'),
            jsonb_build_object('person_id','__lp_member__','first_name','LP','last_name','Member','language','en',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7802,'as_of','2026-10-25')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  DELETE FROM agent.llm_held_messages; DELETE FROM core.llm_incidents;
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.llm_pause.back', 'de', 'BACK', 'core'),
    ('core.llm_pause.back', 'en', 'BACK-EN', 'core'),
    ('core.llm_pause.back_held_one', 'en', 'ONE {when} {quote}', 'core'),
    ('core.llm_pause.back_held_many', 'de', 'MANY {count} {when} {quote}', 'core'),
    ('core.llm_pause.back_held_voice', 'de', 'VOICE {when}', 'core'),
    ('core.llm_pause.still_blocked', 'de', 'STILL', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;

  -- (1) ohne Vorfall nichts faellig
  r := core.fn_llm_probe_due('{}'::jsonb);
  IF (r->>'due')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 ohne Vorfall]: %', r; END IF;

  -- (2) Limit ohne Wahl: erste Nachschau nach 10 Min, Sperre, danach 30, dann 60
  r := core.fn_llm_incident_note(jsonb_build_object('code','spend_limit','resume_at','2026-12-01T00:00:00Z','source','error_notify'));
  inc := (r->>'incident_id')::bigint;
  r := core.fn_llm_probe_due(jsonb_build_object('at', t0 + interval '9 minutes'));
  IF (r->>'due')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 zu frueh]: %', r; END IF;
  r := core.fn_llm_probe_due(jsonb_build_object('at', t0 + interval '11 minutes'));
  IF (r->>'due')::boolean IS NOT TRUE OR (r->>'incident_id')::bigint <> inc OR r->>'opened_at' IS NULL THEN RAISE EXCEPTION 'FAIL [2 faellig]: %', r; END IF;
  r := core.fn_llm_probe_due(jsonb_build_object('at', t0 + interval '11 minutes'));
  IF (r->>'due')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 Sperre]: %', r; END IF;
  -- Knopf: sofort, trotz Sperre und vor dem Plan-Zeitpunkt (sonst kaeme nach dem Toast nichts)
  r := core.fn_llm_probe_due(jsonb_build_object('at', t0 + interval '11 minutes', 'trigger', 'button'));
  IF (r->>'due')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [2 Knopf trotz Sperre]: %', r; END IF;
  r := core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', false, 'code', 'spend_limit', 'trigger', 'cron', 'at', t0 + interval '11 minutes'));
  IF jsonb_array_length(r->'messages') <> 0
     OR (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) <> t0 + interval '41 minutes'
     OR (SELECT probe_lock_until FROM core.llm_incidents WHERE id = inc) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2 naechste 30 Min]: % / %', r, (SELECT row_to_json(i) FROM core.llm_incidents i WHERE id = inc); END IF;
  PERFORM core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', false, 'trigger', 'cron', 'at', t0 + interval '41 minutes'));
  PERFORM core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', false, 'trigger', 'cron', 'at', t0 + interval '101 minutes'));
  IF (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) <> t0 + interval '161 minutes' THEN
    RAISE EXCEPTION 'FAIL [2 dann 60 Min]: %', (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc); END IF;

  -- (3) Knopf-Nachschau gescheitert: Satz + Knopf an den Owner
  r := core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', false, 'trigger', 'button', 'at', t0 + interval '2 hours'));
  m := r->'messages'->0;
  IF jsonb_array_length(r->'messages') <> 1 OR m->>'chat_id' <> '7801' OR position('STILL' in m->>'text') = 0
     OR m->'buttons'->0->0->>'data' <> 'llm:check:' || inc THEN RAISE EXCEPTION 'FAIL [3 Knopf noch gesperrt]: %', r; END IF;

  -- (4) raise: alle 10 Min; wait: ab resume_at + 1 Min
  UPDATE core.llm_incidents SET owner_choice = 'raise' WHERE id = inc;
  PERFORM core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', false, 'trigger', 'cron', 'at', t0 + interval '3 hours'));
  IF (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) <> t0 + interval '3 hours 10 minutes' THEN RAISE EXCEPTION 'FAIL [4 raise]'; END IF;
  UPDATE core.llm_incidents SET owner_choice = 'wait' WHERE id = inc;
  PERFORM core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', false, 'trigger', 'cron', 'at', t0 + interval '4 hours'));
  -- vor dem Datum: genau resume_at + 1 Min; danach (Datum schon vorbei) wieder alle 10 Min
  IF (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) <> (SELECT CASE WHEN t0 + interval '4 hours' < timestamptz '2026-12-01T00:01:00Z'
        THEN timestamptz '2026-12-01T00:01:00Z' ELSE t0 + interval '4 hours 10 minutes' END) THEN
    RAISE EXCEPTION 'FAIL [4 wait]: %', (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc); END IF;

  -- (5) Erholung: Owner-Entwarnung mit seinen 2 Nachrichten (Anzahl + letzte), Mitglied mit Zitat, Sprachnachricht extra
  INSERT INTO agent.llm_held_messages (update_id, incident_id, chat_id, from_id, message_id, kind, payload, sent_at) VALUES
    (9200001, inc, 7801, 7801, 1, 'text', '{"message":{"text":"erste"}}', t0 - interval '5 minutes'),
    (9200002, inc, 7801, 7801, 2, 'text', '{"message":{"text":"zweite Frage"}}', t0 - interval '4 minutes'),
    (9200003, inc, 7802, 7802, 3, 'text', '{"message":{"text":"member question"}}', t0 - interval '3 minutes');
  r := core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', true, 'trigger', 'cron', 'at', t0 + interval '5 hours'));
  IF NOT EXISTS (SELECT 1 FROM core.llm_incidents WHERE id = inc AND close_reason = 'recovered' AND closed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL [5 geschlossen]'; END IF;
  IF jsonb_array_length(r->'messages') <> 2 THEN RAISE EXCEPTION 'FAIL [5 zwei Nachrichten]: %', r; END IF;
  SELECT x INTO m FROM jsonb_array_elements(r->'messages') x WHERE x->>'chat_id' = '7801';
  IF position('BACK' in m->>'text') = 0 OR position('MANY 2' in m->>'text') = 0 OR position('zweite Frage' in m->>'text') = 0
     OR m->'buttons'->0->0->>'data' <> 'llm:replay:' || inc OR m->'buttons'->0->1->>'data' <> 'llm:drop:' || inc THEN
    RAISE EXCEPTION 'FAIL [5 Owner]: %', m; END IF;
  SELECT x INTO m FROM jsonb_array_elements(r->'messages') x WHERE x->>'chat_id' = '7802';
  IF position('BACK-EN' in m->>'text') = 0 OR position('ONE' in m->>'text') = 0 OR position('member question' in m->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL [5 Mitglied]: %', m; END IF;
  -- gemerkte Nachrichten bleiben bis Beantworten/Verwerfen
  IF (SELECT count(*) FROM agent.llm_held_messages) <> 3 THEN RAISE EXCEPTION 'FAIL [5 bleiben]'; END IF;

  -- (6) Stoerung: 2/5/10 Min; Erholung ohne gemerkte Nachricht -> keine Nachricht (Owner-Entscheidung „nie“)
  DELETE FROM agent.llm_held_messages;
  r := core.fn_llm_incident_note(jsonb_build_object('code','unreachable','source','error_notify'));
  inc := (r->>'incident_id')::bigint;
  IF (SELECT next_probe_at - opened_at FROM core.llm_incidents WHERE id = inc) <> interval '2 minutes' THEN RAISE EXCEPTION 'FAIL [6 erste 2 Min]'; END IF;
  PERFORM core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', false, 'trigger', 'cron', 'at', t0 + interval '6 hours'));
  IF (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) <> t0 + interval '6 hours 5 minutes' THEN RAISE EXCEPTION 'FAIL [6 dann 5 Min]'; END IF;
  r := core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', true, 'trigger', 'cron', 'at', t0 + interval '7 hours'));
  IF jsonb_array_length(r->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL [6 Stoerung ohne Owner-Nachricht]: %', r; END IF;

  -- (7) Sprachnachricht: eigener Satz, kein Nachspiel-Knopf, wenn nur sie gemerkt ist
  r := core.fn_llm_incident_note(jsonb_build_object('code','overloaded','source','orchestrator','chat_id','7801',
     'update','{"update_id":9200010,"message":{"message_id":10,"date":1795600000,"chat":{"id":7801,"type":"private"},"from":{"id":7801},"voice":{"file_id":"v9"}}}'::jsonb));
  inc := (r->>'incident_id')::bigint;
  r := core.fn_llm_probe_result(jsonb_build_object('incident_id', inc, 'ok', true, 'trigger', 'cron', 'at', t0 + interval '8 hours'));
  m := r->'messages'->0;
  IF jsonb_array_length(r->'messages') <> 1 OR position('VOICE' in m->>'text') = 0 OR COALESCE(jsonb_array_length(m->'buttons'), 0) <> 0
     OR EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE kind = 'voice') THEN RAISE EXCEPTION 'FAIL [7 Sprachnachricht]: %', r; END IF;

  -- (8) Aufraeumen: gemerkte Nachrichten eines vor > 7 Tagen beendeten Vorfalls verschwinden beim naechsten Aufruf
  INSERT INTO core.llm_incidents (kind, next_probe_at, opened_at, closed_at, close_reason)
  VALUES ('outage', t0 - interval '9 days', t0 - interval '9 days', t0 - interval '8 days', 'recovered') RETURNING id INTO inc;
  INSERT INTO agent.llm_held_messages (update_id, incident_id, chat_id, from_id, message_id, kind, payload, sent_at)
  VALUES (9200020, inc, 7801, 7801, 20, 'text', '{"message":{"text":"alt"}}', t0 - interval '9 days');
  PERFORM core.fn_llm_probe_due('{}'::jsonb);
  IF EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE update_id = 9200020) THEN RAISE EXCEPTION 'FAIL [8 Aufraeumen]'; END IF;
END $$;

ROLLBACK;
