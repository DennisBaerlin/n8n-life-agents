-- tests/db/core/test_fn_handle_llm_cb.sql
-- core.fn_handle_llm_cb(p) — Knoepfe der KI-Pause (Prefix llm, ueber core.fn_dispatch_callback): guide/wait/check nur der
--   Owner (Mitglied -> Toast), guide setzt raise + liefert die Anleitung mit [Erledigt], wait nur mit Datum, check -> route
--   llm_probe + Nachschau sofort faellig, beendeter Vorfall -> Toast; replay liefert route replay + ein zusammengefuehrtes
--   Update aus den eigenen gemerkten Texten/Dateien (Sprachnachricht nicht) und loescht sie, drop loescht; fremde
--   Nachrichten nie. Ausserdem der Weg ueber den Dispatcher (member_permeable). Alle Werte erfunden.
BEGIN;

SET LOCAL TimeZone = 'Europe/Berlin';

DO $$
DECLARE
  r jsonb; inc bigint;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'llm_cb fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__lc_owner__','first_name','LC','last_name','Owner','language','de',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7901,'as_of','2026-10-25'),
            jsonb_build_object('person_id','__lc_member__','first_name','LC','last_name','Member','language','de',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7902,'as_of','2026-10-25')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  DELETE FROM agent.llm_held_messages; DELETE FROM core.llm_incidents;
  INSERT INTO core.callback_handlers (prefix, handler_fn, member_permeable, package)
  VALUES ('llm', 'core.fn_handle_llm_cb', true, 'core')
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = excluded.handler_fn, member_permeable = excluded.member_permeable;

  r := core.fn_llm_incident_note(jsonb_build_object('code','spend_limit','resume_at','2026-12-01T00:00:00Z','source','error_notify'));
  inc := (r->>'incident_id')::bigint;

  -- (1) guide: Mitglied nein, Owner ja (raise, Anleitung mit [Erledigt], Karte behaelt Text, Knoepfe weg)
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:guide:' || inc, 'chat_id', '7902', 'chat_type', 'private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS NULL THEN RAISE EXCEPTION 'FAIL [1 Mitglied guide]: %', r; END IF;
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:guide:' || inc, 'chat_id', '7901', 'chat_type', 'private'));
  -- Quittung nie leer: der Orchestrator ersetzt einen leeren Toast durch „Aktion nicht verfuegbar“
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'reply'->'buttons'->0->0->>'data' <> 'llm:check:' || inc
     OR COALESCE(r->>'toast', '') = '' OR (r->'edit'->>'keep_text')::boolean IS NOT TRUE
     OR (SELECT owner_choice FROM core.llm_incidents WHERE id = inc) <> 'raise'
     OR (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) > now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'FAIL [1 Owner guide]: %', r; END IF;

  -- (2) wait: setzt wait, naechste Nachschau zum Datum + 1 Min, Antwort mit [Limit erhoehen]
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:wait:' || inc, 'chat_id', '7901', 'chat_type', 'private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT owner_choice FROM core.llm_incidents WHERE id = inc) <> 'wait'
     OR (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) <> timestamptz '2026-12-01T00:01:00Z'
     OR r->'reply'->'buttons'->0->0->>'data' <> 'llm:guide:' || inc OR COALESCE(r->>'toast', '') = '' THEN RAISE EXCEPTION 'FAIL [2 wait]: %', r; END IF;

  -- (3) check: route llm_probe, Nachschau sofort faellig
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:check:' || inc, 'chat_id', '7901', 'chat_type', 'private'));
  IF r->>'route' <> 'llm_probe' OR (SELECT next_probe_at FROM core.llm_incidents WHERE id = inc) > now()
     OR ((core.fn_llm_probe_due('{}'::jsonb))->>'due')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 check]: %', r; END IF;

  -- (4) wait ohne Datum (Guthaben) -> Toast, nichts gesetzt
  UPDATE core.llm_incidents SET closed_at = now(), close_reason = 'recovered' WHERE id = inc;
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:guide:' || inc, 'chat_id', '7901', 'chat_type', 'private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS NULL THEN RAISE EXCEPTION 'FAIL [4 beendeter Vorfall]: %', r; END IF;
  r := core.fn_llm_incident_note(jsonb_build_object('code','credit_empty','source','error_notify'));
  inc := (r->>'incident_id')::bigint;
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:wait:' || inc, 'chat_id', '7901', 'chat_type', 'private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR (SELECT owner_choice FROM core.llm_incidents WHERE id = inc) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [4 wait ohne Datum]: %', r; END IF;

  -- (5) replay: eigene Texte + Datei zusammengefuehrt (Datei primaer, Texte als Bildunterschrift), Sprachnachricht nicht;
  --     fremde Nachricht bleibt; die eigenen sind danach weg
  INSERT INTO agent.llm_held_messages (update_id, incident_id, chat_id, from_id, message_id, kind, payload, sent_at) VALUES
    (9300001, inc, 7902, 7902, 11, 'text', '{"update_id":9300001,"message":{"message_id":11,"chat":{"id":7902,"type":"private"},"from":{"id":7902},"text":"erste"}}', now()),
    (9300002, inc, 7902, 7902, 12, 'file', '{"update_id":9300002,"message":{"message_id":12,"chat":{"id":7902,"type":"private"},"from":{"id":7902},"document":{"file_id":"d1","file_name":"a.pdf"}}}', now()),
    (9300003, inc, 7902, 7902, 13, 'text', '{"update_id":9300003,"message":{"message_id":13,"chat":{"id":7902,"type":"private"},"from":{"id":7902},"text":"zweite"}}', now()),
    (9300004, inc, 7902, 7902, 14, 'voice', '{"update_id":9300004,"message":{"message_id":14,"chat":{"id":7902,"type":"private"},"from":{"id":7902},"voice":{"file_id":"v1"}}}', now()),
    (9300005, inc, 7901, 7901, 15, 'text', '{"update_id":9300005,"message":{"message_id":15,"chat":{"id":7901,"type":"private"},"from":{"id":7901},"text":"owner"}}', now());
  -- ueber den Dispatcher (member_permeable): ein Mitglied erreicht den Handler
  r := core.fn_dispatch_callback(jsonb_build_object('data', 'llm:replay:' || inc, 'chat_id', '7902', 'chat_type', 'private'));
  IF r->>'route' <> 'replay' OR r->'update'->'message'->'document'->>'file_id' <> 'd1'
     OR r->'update'->'message'->>'caption' <> E'erste\n\nzweite' OR r->'update'->'message'->'from'->>'id' <> '7902'
     OR (r->'edit'->>'keep_text')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5 replay]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE from_id = 7902)
     OR NOT EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE from_id = 7901) THEN RAISE EXCEPTION 'FAIL [5 nur eigene geloescht]'; END IF;
  -- nichts mehr offen -> Toast, keine Route
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:replay:' || inc, 'chat_id', '7902', 'chat_type', 'private'));
  IF r->>'route' IS NOT NULL OR r->>'toast' IS NULL THEN RAISE EXCEPTION 'FAIL [5 nichts offen]: %', r; END IF;

  -- (5b) gemerktes Update ist selbst schon ein Buendel (Foto + 2 extra_files), danach noch ein Foto: alle vier Dateien bleiben
  INSERT INTO agent.llm_held_messages (update_id, incident_id, chat_id, from_id, message_id, kind, payload, sent_at) VALUES
    (9300011, inc, 7902, 7902, 21, 'file', '{"update_id":9300011,"message":{"message_id":21,"chat":{"id":7902,"type":"private"},"from":{"id":7902},"photo":[{"file_id":"p1"}],"caption":"Belege","extra_files":[{"file_id":"p2","type":"photo"},{"file_id":"p3","type":"photo"}]}}', now()),
    (9300012, inc, 7902, 7902, 22, 'file', '{"update_id":9300012,"message":{"message_id":22,"chat":{"id":7902,"type":"private"},"from":{"id":7902},"photo":[{"file_id":"p4"}]}}', now());
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:replay:' || inc, 'chat_id', '7902', 'chat_type', 'private'));
  IF r->'update'->'message'->'photo'->0->>'file_id' <> 'p1'
     OR (SELECT string_agg(e->>'file_id', ',' ORDER BY o) FROM jsonb_array_elements(r->'update'->'message'->'extra_files') WITH ORDINALITY x(e, o)) <> 'p2,p3,p4'
     OR r->'update'->'message'->>'caption' <> 'Belege' THEN RAISE EXCEPTION 'FAIL [5b Buendel nachspielen]: %', r->'update'; END IF;

  -- (6) ein einzelner Text: das Update unveraendert; drop loescht nur die eigenen
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:replay:' || inc, 'chat_id', '7901', 'chat_type', 'private'));
  IF r->'update'->'message'->>'text' <> 'owner' OR r->'update'->>'update_id' <> '9300005' THEN RAISE EXCEPTION 'FAIL [6 einzeln]: %', r; END IF;
  INSERT INTO agent.llm_held_messages (update_id, incident_id, chat_id, from_id, message_id, kind, payload, sent_at) VALUES
    (9300006, inc, 7901, 7901, 16, 'text', '{"message":{"text":"x"}}', now()),
    (9300007, inc, 7902, 7902, 17, 'text', '{"message":{"text":"y"}}', now());
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:drop:' || inc, 'chat_id', '7901', 'chat_type', 'private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE from_id = 7901)
     OR NOT EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE from_id = 7902) THEN RAISE EXCEPTION 'FAIL [6 drop]: %', r; END IF;

  -- (7) kaputte Daten / Gruppenchat -> ok:false, nie RAISE
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:quatsch:x', 'chat_id', '7901', 'chat_type', 'private'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 unbekannt]: %', r; END IF;
  r := core.fn_handle_llm_cb(jsonb_build_object('data', 'llm:replay:' || inc, 'chat_id', '7902', 'chat_type', 'group'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 Gruppe]: %', r; END IF;
END $$;

ROLLBACK;
