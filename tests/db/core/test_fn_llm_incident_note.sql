-- tests/db/core/test_fn_llm_incident_note.sql
-- core.fn_llm_incident_note(p) — Pause der KI melden: Vorfall oeffnen/uebernehmen (hoechstens einer offen), Art aus dem
--   Gateway-Code, Owner-Karte einmal je Vorfall (als Antwort, wenn der Owner selbst schrieb, sonst owner_card), Mitglieder
--   ohne Knoepfe und Betrag, Stoerung ohne Owner-Nachricht, schwererer Fall ersetzt die Stoerung (gemerkte Nachrichten
--   ziehen mit), keine Herabstufung, rate_limited/other ohne Vorfall, Nachrichten merken (text/file/voice, Befehle nicht,
--   10 je Absender), Verbrauch im UTC-Monat aus core.v_llm_usage_cost, Datum/Uhrzeit in der Sitzungs-Zeitzone.
--   Alle Werte erfunden.
BEGIN;

SET LOCAL TimeZone = 'Europe/Berlin';

DO $$
DECLARE
  r jsonb; r2 jsonb; inc bigint; inc2 bigint; n int; t text;
  upd_a jsonb := '{"update_id":9100001,"message":{"message_id":501,"date":1795600000,"chat":{"id":7701,"type":"private"},"from":{"id":7701},"text":"Frage A"}}';
  month_start timestamptz := (date_trunc('month', now() AT TIME ZONE 'UTC')) AT TIME ZONE 'UTC';
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'llm_incident fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__li_owner__','first_name','LI','last_name','Owner','language','de',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7701,'as_of','2026-10-25'),
            jsonb_build_object('person_id','__li_member__','first_name','LI','last_name','Member','language','en',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7702,'as_of','2026-10-25')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

  DELETE FROM agent.llm_held_messages; DELETE FROM core.llm_incidents; DELETE FROM core.llm_usage;
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.llm_pause.owner_spend_limit', 'de', 'OWNER-SPEND', 'core'),
    ('core.llm_pause.spent_line', 'de', 'S={usd}', 'core'),
    ('core.llm_pause.resume_line', 'de', 'R={date}/{time}', 'core'),
    ('core.llm_pause.held_line', 'de', 'H={when}', 'core'),
    ('core.llm_pause.owner_again_spend_limit', 'de', 'AGAIN', 'core'),
    ('core.llm_pause.member_spend_limit', 'en', 'MEMBER-SPEND', 'core'),
    ('core.llm_pause.outage', 'de', 'OUTAGE', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;

  -- Verbrauch: 30 Mio Input x 1 USD = 30 im laufenden UTC-Monat; 99 im Vormonat (zaehlt nicht); Fehlerzeile 0 Tokens.
  INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode, pricing_usd_per_mtok) VALUES
    ('zz-li-a', 'Anthropic', 'zz-li-model', NULL, 'embedding', '{"input":1,"cache_write_5m":2,"cache_write_1h":4,"cache_read":0.5,"output":10}');
  INSERT INTO core.llm_usage (id, ts, wf, model, keepalive, input_tokens, status, err_code) VALUES
    ('1000000000101-bbbbbb-000001', month_start + interval '1 hour', 'agent.finance', 'zz-li-model', false, 30000000, 200, NULL),
    ('1000000000102-bbbbbb-000002', month_start - interval '1 hour', 'agent.finance', 'zz-li-model', false, 99000000, 200, NULL),
    ('1000000000103-bbbbbb-000003', now(), 'agent.orchestrator.main_route', 'zz-li-model', false, 0, 400, 'spend_limit');

  -- (1) Owner schreibt, Monatslimit mit Datum -> Karte als Antwort mit zwei Knoepfen, Nachricht gemerkt
  r := core.fn_llm_incident_note(jsonb_build_object('code','spend_limit','resume_at','2026-12-01T00:00:00Z','source','orchestrator',
         'chat_id','7701','update', upd_a));
  inc := (r->>'incident_id')::bigint;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'kind' <> 'spend_limit' OR inc IS NULL OR (r->>'suppress_alert')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1 Grundfelder]: %', r; END IF;
  IF jsonb_array_length(r->'reply_buttons') <> 2
     OR r->'reply_buttons'->0->0->>'data' <> 'llm:guide:' || inc OR r->'reply_buttons'->1->0->>'data' <> 'llm:wait:' || inc THEN
    RAISE EXCEPTION 'FAIL [1 Knoepfe]: %', r->'reply_buttons'; END IF;
  t := r->>'reply_text';
  IF position('OWNER-SPEND' in t) = 0 OR position('S=30' in t) = 0
     OR position('R=' || core.fn_fmt_date(date '2026-12-01', 'de') || '/01:00' in t) = 0 OR position('H=' in t) = 0 THEN
    RAISE EXCEPTION 'FAIL [1 Text]: %', t; END IF;
  IF r->'owner_card' IS NOT NULL AND r->'owner_card' <> 'null'::jsonb THEN RAISE EXCEPTION 'FAIL [1 keine zweite Karte]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.llm_incidents WHERE id = inc AND owner_notified_at IS NOT NULL
                   AND resume_at = '2026-12-01T00:00:00Z' AND next_probe_at > now()) THEN RAISE EXCEPTION 'FAIL [1 Zeile]'; END IF;
  IF (SELECT count(*) FROM agent.llm_held_messages WHERE incident_id = inc AND kind = 'text') <> 1 THEN RAISE EXCEPTION 'FAIL [1 gemerkt]'; END IF;

  -- (2) Owner schreibt erneut: kurzer Satz, keine Knoepfe, dieselbe Pause, zweite Nachricht gemerkt
  r := core.fn_llm_incident_note(jsonb_build_object('code','spend_limit','resume_at','2026-12-01T00:00:00Z','source','orchestrator',
         'chat_id','7701','update', jsonb_set(jsonb_set(upd_a, '{update_id}', '9100002'), '{message,message_id}', '502')));
  IF (r->>'incident_id')::bigint <> inc OR position('AGAIN' in r->>'reply_text') = 0 OR COALESCE(jsonb_array_length(r->'reply_buttons'), 0) <> 0 THEN
    RAISE EXCEPTION 'FAIL [2 erneut]: %', r; END IF;
  -- dieselbe update_id noch einmal (Webhook-Wiederholung) -> keine zweite Zeile
  PERFORM core.fn_llm_incident_note(jsonb_build_object('code','spend_limit','source','orchestrator','chat_id','7701',
         'update', jsonb_set(jsonb_set(upd_a, '{update_id}', '9100002'), '{message,message_id}', '502')));
  IF (SELECT count(*) FROM agent.llm_held_messages) <> 2 THEN RAISE EXCEPTION 'FAIL [2 Dedupe]'; END IF;

  -- (3) Mitglied schreibt: eigener Text, keine Knoepfe, kein Betrag, keine zweite Owner-Karte
  r := core.fn_llm_incident_note(jsonb_build_object('code','spend_limit','resume_at','2026-12-01T00:00:00Z','source','orchestrator',
         'chat_id','7702','update', '{"update_id":9100003,"message":{"message_id":601,"date":1795600100,"chat":{"id":7702,"type":"private"},"from":{"id":7702},"text":"Question B"}}'::jsonb));
  IF position('MEMBER-SPEND' in r->>'reply_text') = 0 OR position('S=' in r->>'reply_text') > 0
     OR COALESCE(jsonb_array_length(r->'reply_buttons'), 0) <> 0 OR (r->'owner_card' IS NOT NULL AND r->'owner_card' <> 'null'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [3 Mitglied]: %', r; END IF;

  -- (4) Herabstufung nein: Stoerung waehrend offenem Limit -> bleibt spend_limit
  r := core.fn_llm_incident_note(jsonb_build_object('code','overloaded','source','error_notify'));
  IF r->>'kind' <> 'spend_limit' OR (r->>'incident_id')::bigint <> inc THEN RAISE EXCEPTION 'FAIL [4 keine Herabstufung]: %', r; END IF;

  -- (5) rate_limited / other: kein Vorfall, Alarm bleibt
  r := core.fn_llm_incident_note(jsonb_build_object('code','other','source','error_notify'));
  IF r->>'kind' IS NOT NULL OR (r->>'suppress_alert')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 other]: %', r; END IF;
  r := core.fn_llm_incident_note(jsonb_build_object('code','rate_limited','source','error_notify'));
  IF r->>'kind' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 rate_limited]: %', r; END IF;
  r := core.fn_llm_incident_note(jsonb_build_object('code','quatsch','source','error_notify'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 unbekannter Code]: %', r; END IF;

  -- (6) Stoerung ohne offenen Vorfall: Text an den Schreiber, keine Owner-Nachricht; Limit danach ersetzt sie
  UPDATE core.llm_incidents SET closed_at = now(), close_reason = 'recovered' WHERE id = inc;
  DELETE FROM agent.llm_held_messages;
  r := core.fn_llm_incident_note(jsonb_build_object('code','overloaded','source','orchestrator','chat_id','7701','update', upd_a));
  inc2 := (r->>'incident_id')::bigint;
  IF r->>'kind' <> 'outage' OR position('OUTAGE' in r->>'reply_text') = 0 OR COALESCE(jsonb_array_length(r->'reply_buttons'), 0) <> 0
     OR (r->'owner_card' IS NOT NULL AND r->'owner_card' <> 'null'::jsonb) THEN RAISE EXCEPTION 'FAIL [6 Stoerung]: %', r; END IF;
  r := core.fn_llm_incident_note(jsonb_build_object('code','credit_empty','source','error_notify'));
  IF r->>'kind' <> 'credit_empty' OR (r->>'incident_id')::bigint = inc2
     OR NOT EXISTS (SELECT 1 FROM core.llm_incidents WHERE id = inc2 AND close_reason = 'superseded')
     OR (SELECT count(*) FROM agent.llm_held_messages WHERE incident_id = (r->>'incident_id')::bigint) <> 1 THEN
    RAISE EXCEPTION 'FAIL [6 ersetzt + mitgezogen]: %', r; END IF;
  -- ohne Schreiber (Cron-Fehler) und Owner noch nicht informiert -> owner_card mit genau einem Knopf (Guthaben-Anleitung)
  IF r->'owner_card' IS NULL OR jsonb_array_length(r->'owner_card'->'buttons') <> 1
     OR r->'owner_card'->'buttons'->0->0->>'data' <> 'llm:guide:' || (r->>'incident_id') THEN RAISE EXCEPTION 'FAIL [6 owner_card]: %', r; END IF;
  r2 := core.fn_llm_incident_note(jsonb_build_object('code','credit_empty','source','error_notify'));
  IF r2->'owner_card' IS NOT NULL AND r2->'owner_card' <> 'null'::jsonb THEN RAISE EXCEPTION 'FAIL [6 Karte nur einmal]: %', r2; END IF;

  -- (7) Stufen-Obergrenze (spend_limit ohne Datum): nur der Anleitungs-Knopf, keine Datumszeile
  UPDATE core.llm_incidents SET closed_at = now(), close_reason = 'recovered' WHERE closed_at IS NULL;
  r := core.fn_llm_incident_note(jsonb_build_object('code','spend_limit','source','orchestrator','chat_id','7701','update', upd_a));
  IF jsonb_array_length(r->'reply_buttons') <> 1 OR position('R=' in r->>'reply_text') > 0 THEN RAISE EXCEPTION 'FAIL [7 ohne Datum]: %', r; END IF;

  -- (8) Schluessel: keine Knoepfe
  UPDATE core.llm_incidents SET closed_at = now(), close_reason = 'recovered' WHERE closed_at IS NULL;
  r := core.fn_llm_incident_note(jsonb_build_object('code','auth','source','orchestrator','chat_id','7701'));
  IF r->>'kind' <> 'auth' OR COALESCE(jsonb_array_length(r->'reply_buttons'), 0) <> 0 THEN RAISE EXCEPTION 'FAIL [8 auth]: %', r; END IF;

  -- (9) Merken: Befehl nicht, Sprachnachricht als voice, Foto als file; hoechstens 10 je Absender (aelteste fallen raus)
  DELETE FROM agent.llm_held_messages;
  PERFORM core.fn_llm_incident_note(jsonb_build_object('code','auth','source','orchestrator','chat_id','7701',
     'update','{"update_id":9100010,"message":{"message_id":700,"date":1795600000,"chat":{"id":7701,"type":"private"},"from":{"id":7701},"text":"/help"}}'::jsonb));
  PERFORM core.fn_llm_incident_note(jsonb_build_object('code','auth','source','orchestrator','chat_id','7701',
     'update','{"update_id":9100011,"message":{"message_id":701,"date":1795600000,"chat":{"id":7701,"type":"private"},"from":{"id":7701},"voice":{"file_id":"v1"}}}'::jsonb));
  PERFORM core.fn_llm_incident_note(jsonb_build_object('code','auth','source','orchestrator','chat_id','7701',
     'update','{"update_id":9100012,"message":{"message_id":702,"date":1795600000,"chat":{"id":7701,"type":"private"},"from":{"id":7701},"photo":[{"file_id":"p1"}]}}'::jsonb));
  IF (SELECT string_agg(kind, ',' ORDER BY message_id) FROM agent.llm_held_messages) <> 'voice,file' THEN
    RAISE EXCEPTION 'FAIL [9 Arten]: %', (SELECT string_agg(kind, ',' ORDER BY message_id) FROM agent.llm_held_messages); END IF;
  FOR n IN 1..12 LOOP
    PERFORM core.fn_llm_incident_note(jsonb_build_object('code','auth','source','orchestrator','chat_id','7701',
       'update', jsonb_build_object('update_id', 9100100 + n, 'message', jsonb_build_object('message_id', 800 + n, 'date', 1795600000 + n,
                 'chat', jsonb_build_object('id', 7701, 'type', 'private'), 'from', jsonb_build_object('id', 7701), 'text', 'T' || n))));
  END LOOP;
  IF (SELECT count(*) FROM agent.llm_held_messages WHERE from_id = 7701) <> 10
     OR EXISTS (SELECT 1 FROM agent.llm_held_messages WHERE message_id IN (701, 702, 801, 802)) THEN
    RAISE EXCEPTION 'FAIL [9 Obergrenze 10]: %', (SELECT array_agg(message_id ORDER BY message_id) FROM agent.llm_held_messages); END IF;

  -- (10) Gesetz: hoechstens ein offener Vorfall
  BEGIN
    INSERT INTO core.llm_incidents (kind, next_probe_at) VALUES ('outage', now());
    RAISE EXCEPTION 'FAIL [10 zweiter offener Vorfall angenommen]';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO core.llm_incidents (kind, resume_at, next_probe_at, closed_at, close_reason) VALUES ('outage', now(), now(), now(), 'recovered');
    RAISE EXCEPTION 'FAIL [10 resume_at bei outage angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;

ROLLBACK;
